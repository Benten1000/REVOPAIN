#!/bin/bash
set -euo pipefail

###############################################################################
# Robust Postfix + OpenDKIM installer + example send script
# - Handles systems without systemd (containers, chroots) by falling back to
#   service/invoke-rc.d/init.d mechanisms.
# - Generates DKIM keypair, configures OpenDKIM, configures Postfix to use it.
# - Prints DKIM public TXT and suggests SPF/DMARC records.
#
# USAGE: sudo ./setup_mail_with_dkim.sh
###############################################################################

# === CONFIGURATION - customize these values ===
myhostname="mail.admailsend.com"
domain="admailsend.com"           # domain to sign for
selector="default"               # dkim selector
sender_name="EMAIL"
email_subject="WEBMAIL"
email_list="list.txt"            # path to recipient list (script also creates)
tmux_session="mail_session"
# === end configuration ===

# Simple root check
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root or with sudo."
  exit 1
fi

# Helper: detect if PID1 is systemd
is_systemd_running() {
  # returns 0 if systemd is PID 1
  if [ -r /proc/1/comm ]; then
    [ "$(cat /proc/1/comm)" = "systemd" ]
    return
  fi
  return 1
}

# Helper: perform service action with fallbacks
# Usage: service_action <service> <action>
# where action is start|stop|restart|reload|status|enable
service_action() {
  local svc="$1"; shift
  local act="$1"; shift

  if is_systemd_running && command -v systemctl >/dev/null 2>&1; then
    echo "Trying: systemctl ${act} ${svc} ..."
    systemctl "${act}" "${svc}" && return 0 || echo "systemctl ${act} ${svc} failed (continuing to fallback)..."
  fi

  if command -v service >/dev/null 2>&1; then
    echo "Trying: service ${svc} ${act} ..."
    # 'service' uses start|stop|restart|status; for reload, some daemons accept it
    service "${svc}" "${act}" && return 0 || echo "service ${svc} ${act} failed..."
  fi

  if command -v invoke-rc.d >/dev/null 2>&1; then
    echo "Trying: invoke-rc.d ${svc} ${act} ..."
    # invoke-rc.d may refuse action in some environments; capture return code
    if invoke-rc.d "${svc}" "${act}"; then
      return 0
    else
      echo "invoke-rc.d ${svc} ${act} returned non-zero (see output)..."
    fi
  fi

  if [ -x "/etc/init.d/${svc}" ]; then
    echo "Trying: /etc/init.d/${svc} ${act} ..."
    "/etc/init.d/${svc}" "${act}" && return 0 || echo "/etc/init.d/${svc} ${act} failed..."
  fi

  echo "All methods to ${act} ${svc} failed or not available. Check service manually."
  return 1
}

echo "Updating package lists..."
apt-get update -y

echo "Installing required packages: postfix, tmux, mailutils, opendkim..."
DEBIAN_FRONTEND=noninteractive apt-get install -y postfix tmux mailutils opendkim opendkim-tools || {
  echo "Package installation failed. Exiting."
  exit 1
}

# === Backup and write Postfix main.cf ===
echo "Backing up /etc/postfix/main.cf to /etc/postfix/main.cf.backup (if not backed up already)..."
if [ ! -f /etc/postfix/main.cf.backup ]; then
  cp /etc/postfix/main.cf /etc/postfix/main.cf.backup || true
fi

echo "Writing a minimal /etc/postfix/main.cf (adjust policies for production)..."
cat > /etc/postfix/main.cf <<EOF
# Minimal Postfix configuration (generated)
myhostname = $myhostname
myorigin = $domain
inet_interfaces = loopback-only
mydestination = localhost
relayhost =
mailbox_size_limit = 0
recipient_delimiter = +
queue_directory = /var/spool/postfix
command_directory = /usr/sbin
daemon_directory = /usr/lib/postfix/sbin

# OpenDKIM milter settings (Postfix will talk to OpenDKIM over inet localhost:12301)
milter_default_action = accept
milter_protocol = 2
smtpd_milters = inet:localhost:12301
non_smtpd_milters = inet:localhost:12301
EOF

# After modifying main.cf: attempt to reload Postfix using the best available mechanism
echo "Reloading Postfix configuration (attempting systemctl reload postfix first)..."
if service_action postfix reload; then
  echo "Postfix reloaded successfully."
else
  # Try restart as a stronger fallback (some environments can't reload)
  echo "Reload failed; trying restart..."
  if service_action postfix restart; then
    echo "Postfix restarted successfully."
  else
    echo "Could not reload or restart Postfix automatically. Please inspect Postfix status manually."
  fi
fi

# Run newaliases (safe to run even if it emits invoke-rc.d warnings)
echo "Running newaliases..."
if newaliases; then
  echo "newaliases ran successfully."
else
  echo "newaliases returned non-zero (this may be benign in some environments)."
fi

# === Setup OpenDKIM configuration and keys ===
OPENDKIM_CONF="/etc/opendkim.conf"
OPENDKIM_DIR="/etc/opendkim"
KEYS_DIR="${OPENDKIM_DIR}/keys"
DOMAIN_KEYS_DIR="${KEYS_DIR}/${domain}"

echo "Creating OpenDKIM directories..."
mkdir -p "$DOMAIN_KEYS_DIR"
chown -R opendkim:opendkim "$OPENDKIM_DIR" || true

echo "Writing /etc/opendkim.conf..."
cat > "$OPENDKIM_CONF" <<EOF
# OpenDKIM configuration (minimal)
Syslog          yes
UMask           002
Socket          inet:12301@localhost
PidFile         /var/run/opendkim/opendkim.pid
Mode            sv
Canonicalization relaxed/simple
Selector        $selector
KeyTable        /etc/opendkim/KeyTable
SigningTable    /etc/opendkim/SigningTable
ExternalIgnoreList /etc/opendkim/TrustedHosts
InternalHosts   /etc/opendkim/TrustedHosts
UserID          opendkim:opendkim
EOF

# KeyTable, SigningTable, TrustedHosts
cat > /etc/opendkim/TrustedHosts <<EOF
127.0.0.1
::1
localhost
$myhostname
EOF

cat > /etc/opendkim/KeyTable <<EOF
# Format: <selector>._domainkey.<domain> <domain>:<selector>:/path/to/private.key
${selector}._domainkey.${domain} ${domain}:${selector}:${DOMAIN_KEYS_DIR}/${selector}.private
EOF

cat > /etc/opendkim/SigningTable <<EOF
# Sign all mail from the domain using the selector above
*@${domain} ${selector}._domainkey.${domain}
EOF

# Ensure correct ownership/perms
chown -R opendkim:opendkim /etc/opendkim
chmod 750 /etc/opendkim
chmod 640 /etc/opendkim/KeyTable /etc/opendkim/SigningTable /etc/opendkim/TrustedHosts || true

# Generate DKIM keypair if not already present
if [ ! -f "${DOMAIN_KEYS_DIR}/${selector}.private" ]; then
  echo "Generating DKIM keypair for ${domain} (selector=${selector})..."
  mkdir -p "$DOMAIN_KEYS_DIR"
  # Generate 2048-bit key
  opendkim-genkey -b 2048 -d "$domain" -s "$selector" -D "$DOMAIN_KEYS_DIR"
  chown opendkim:opendkim "${DOMAIN_KEYS_DIR}/${selector}.private" "${DOMAIN_KEYS_DIR}/${selector}.txt" || true
  chmod 600 "${DOMAIN_KEYS_DIR}/${selector}.private" || true
  echo "DKIM keypair generated at ${DOMAIN_KEYS_DIR}/${selector}.private"
else
  echo "DKIM keypair already exists at ${DOMAIN_KEYS_DIR}/${selector}.private — skipping generation."
fi

# Make sure opendkim user can access keys
chown -R opendkim:opendkim "${KEYS_DIR}" || true
chmod -R 750 "${KEYS_DIR}" || true
chmod 600 "${DOMAIN_KEYS_DIR}/${selector}.private" || true

# Start/restart OpenDKIM using robust mechanism
echo "Starting/restarting OpenDKIM..."
if service_action opendkim restart; then
  echo "OpenDKIM restarted via available mechanism."
else
  echo "Could not restart OpenDKIM via standard mechanisms. Try: service opendkim restart or systemctl restart opendkim if available."
fi

# Ensure Postfix knows about the milter (we already wrote main.cf above)
# Reload/restart Postfix again to ensure it picks up the milter settings
echo "Ensuring Postfix is running with updated milter settings..."
if service_action postfix reload; then
  echo "Postfix reloaded after OpenDKIM changes."
else
  echo "Postfix reload failed; attempting restart..."
  if service_action postfix restart; then
    echo "Postfix restarted."
  else
    echo "Failed to restart Postfix automatically; check manually."
  fi
fi

# === Create email template ===
echo "Creating email.html template..."
cat > email.html <<'HTML'
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>Letter</title>
</head>
<body>
  <p>Hello,</p>
  <p>This is a test letter addressed to {{EMAIL}}. Subdomain: {{SUBDOMAIN}}</p>
  <p>Kind regards,<br/>EMAIL</p>
</body>
</html>
HTML

chmod 664 email.html || true

# === Create send.sh script that sends signed mail (OpenDKIM will sign automatically) ===
echo "Creating send.sh..."
cat > send.sh <<'SH'
#!/bin/bash
set -euo pipefail

email_list_file="'"$email_list"'"
counter=1

if [ ! -f "$email_list_file" ]; then
  echo "Recipient list file $email_list_file not found. Create it and add one email per line."
  exit 1
fi

while IFS= read -r email || [ -n "$email" ]; do
  # Skip empty lines and comments
  [[ -z "$email" ]] && continue
  [[ "$email" =~ ^# ]] && continue

  echo "Sending email to: $email"

  from_username="supportzed${counter}"
  from_domain="'"$domain"'"
  from_email="${from_username}@${from_domain}"
  from_name="'"$sender_name"'"
  from_header="${from_name} <${from_email}>"

  random_number=$(shuf -i 100-999 -n 1)
  subject="'"$email_subject"' - SECURE ! ($random_number)"

  subdomain=$(tr -dc 'a-z' </dev/urandom | head -c3 || echo "abc")
  # Replace placeholders in email.html
  html_content=$(sed "s/{{EMAIL}}/${email}/g; s/{{SUBDOMAIN}}/${subdomain}/g" email.html)

  # Construct and send MIME email via sendmail (Postfix will hand to OpenDKIM milter)
  cat <<EOF | /usr/sbin/sendmail -t -oi
To: ${email}
From: ${from_header}
Subject: ${subject}
MIME-Version: 1.0
Content-Type: text/html; charset="utf-8"

${html_content}
EOF

  # increment counter
  ((counter++))
  # Small sleep to avoid hammering the queue too fast
  sleep 0.5
done < "$email_list_file"
SH

chmod +x send.sh || true

# Create an empty list.txt if missing (user will populate)
if [ ! -f "$email_list" ]; then
  echo "Creating empty $email_list; please populate with one recipient per line."
  cat > "$email_list" <<EOF
# Add one recipient email per line, e.g.:
# user@example.com
EOF
  chmod 664 "$email_list" || true
fi

# Start the send script in a detached tmux session (only if tmux exists)
if command -v tmux >/dev/null 2>&1; then
  if tmux ls 2>/dev/null | grep -q "^${tmux_session}:"; then
    echo "tmux session ${tmux_session} already exists. Not creating a new one."
  else
    echo "Starting tmux session '${tmux_session}' to run ./send.sh ..."
    tmux new-session -d -s "$tmux_session" "./send.sh"
  fi
else
  echo "tmux not found; please run ./send.sh manually or install tmux."
fi

# === Print DKIM TXT for DNS ===
DKIM_TXT_FILE="${DOMAIN_KEYS_DIR}/${selector}.txt"
echo
echo "=================================================================="
if [ -f "$DKIM_TXT_FILE" ]; then
  echo "DKIM public key file: $DKIM_TXT_FILE"
  echo "Contents (as generated):"
  echo "------------------------------------------------------------------"
  cat "$DKIM_TXT_FILE"
  echo "------------------------------------------------------------------"

  # Extract the quoted TXT components and join them into one string
  txt_value=$(sed -n 's/^[^"]*"\(.*\)".*$/\1/p' "$DKIM_TXT_FILE" | tr -d '\n' || true)

  if [ -n "$txt_value" ]; then
    echo "Suggested DNS TXT record (host and value) to publish:"
    echo
    echo "Host: ${selector}._domainkey.${domain}"
    echo "TXT: \"${txt_value}\""
    echo
    echo "Note: Some DNS providers require you to omit the surrounding quotes; they will add them automatically."
  else
    echo "Could not parse tidy TXT. Use the file $DKIM_TXT_FILE contents above when creating DNS TXT."
  fi
else
  echo "Expected DKIM file $DKIM_TXT_FILE not found."
fi

# === Suggest SPF and DMARC ===
echo
echo "Suggested SPF and DMARC records to publish in DNS for ${domain}:"
echo "------------------------------------------------------------------"
echo "SPF (publish as TXT record for the domain):"
echo
echo "${domain}. IN TXT \"v=spf1 mx ~all\""
echo
echo "This means: allow mail from the domain's MX servers. Modify if you send from other hosts/IPs (add ip4: or include: mechanisms)."
echo
echo "DMARC (publish as TXT for _dmarc.${domain}):"
echo
echo "_dmarc.${domain}. IN TXT \"v=DMARC1; p=none; rua=mailto:postmaster@${domain}; pct=100\""
echo
echo "Change p=none to p=quarantine or p=reject only after you validate SPF/DKIM and monitor reports."
echo "------------------------------------------------------------------"

echo
echo "✅ Setup attempted. Postfix and OpenDKIM installation/config completed where possible."
echo "If you saw 'System has not been booted with systemd' messages earlier, the script attempted fallbacks."
echo
echo "Check service status manually if needed:"
echo "  * Check Postfix queue: postqueue -p"
echo "  * Check OpenDKIM logs: journalctl -u opendkim (systemd) or check /var/log/mail.log /var/log/syslog"
echo "To reattach tmux: tmux attach -t ${tmux_session}"
echo "To stop sending, kill the tmux session: tmux kill-session -t ${tmux_session}"
echo
echo "Remember to publish the DKIM TXT, SPF, and DMARC records in your DNS for domain ${domain}."
echo "You can verify DKIM signing by sending a test email to a Gmail account or using tools like 'swaks' and then inspecting headers for 'DKIM-Signature'."
echo

exit 0
