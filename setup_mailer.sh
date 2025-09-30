#!/bin/bash
set -euo pipefail

###############################################################################
# Automated Postfix + OpenDKIM setup + example send script
# - Domain: admailsend.com (change below if needed)
# - Selector: default
# - Prints DKIM public TXT for DNS and suggests SPF/DMARC records
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

echo "Updating package lists..."
apt-get update -y

echo "Installing required packages: postfix, tmux, mailutils, opendkim..."
DEBIAN_FRONTEND=noninteractive apt-get install -y postfix tmux mailutils opendkim opendkim-tools

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

echo "Restarting Postfix..."
systemctl restart postfix || service postfix restart || true

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
  opendkim-genkey -b 2048 -d "$domain" -s "$selector" -D "$DOMAIN_KEYS_DIR"
  chown opendkim:opendkim "${DOMAIN_KEYS_DIR}/${selector}.private" "${DOMAIN_KEYS_DIR}/${selector}.txt"
  chmod 600 "${DOMAIN_KEYS_DIR}/${selector}.private"
  echo "DKIM keypair generated at ${DOMAIN_KEYS_DIR}/${selector}.private"
else
  echo "DKIM keypair already exists at ${DOMAIN_KEYS_DIR}/${selector}.private — skipping generation."
fi

# Make sure opendkim user can access keys
chown -R opendkim:opendkim "${KEYS_DIR}"
chmod -R 750 "${KEYS_DIR}"
chmod 600 "${DOMAIN_KEYS_DIR}/${selector}.private"

# Ensure opendkim service is enabled and started
echo "Restarting/starting OpenDKIM..."
if systemctl list-unit-files | grep -q opendkim; then
  systemctl restart opendkim || service opendkim restart || true
  systemctl enable opendkim || true
else
  # Try to start directly if systemctl unit name differs
  service opendkim restart || true
fi

# Ensure Postfix can talk to OpenDKIM (restart Postfix again)
systemctl restart postfix || service postfix restart || true

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

chmod 664 email.html

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

chmod +x send.sh

# Create an empty list.txt if missing (user will populate)
if [ ! -f "$email_list" ]; then
  echo "Creating empty $email_list; please populate with one recipient per line."
  cat > "$email_list" <<EOF
# Add one recipient email per line, e.g.:
# user@example.com
EOF
  chmod 664 "$email_list"
fi

# Start the send script in a detached tmux session (if not already running)
if tmux ls 2>/dev/null | grep -q "^${tmux_session}:"; then
  echo "tmux session ${tmux_session} already exists. Not creating a new one."
else
  echo "Starting tmux session '${tmux_session}' to run ./send.sh ..."
  tmux new-session -d -s "$tmux_session" "./send.sh"
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

  # Attempt to extract the host and TXT value in a single-line DNS-friendly format
  # The generated file often contains something like:
  # default._domainkey IN TXT ( "v=DKIM1; k=rsa; p=MIIBI..." ) ; ----- DKIM key ...
  # We'll normalize to: Host: default._domainkey.admailsend.com  TXT: "v=DKIM1; k=rsa; p=MIIBI..."
  host_line=$(grep -oP '^[^ ]+' "$DKIM_TXT_FILE" | head -n1 || true)
  # Extract the quoted TXT components and join them into one string
  txt_value=$(sed -n 's/^[^"]*"\(.*\)".*$/\1/p' "$DKIM_TXT_FILE" | tr -d '\n' | sed 's/")/"/g' || true)

  if [ -n "$host_line" ] && [ -n "$txt_value" ]; then
    # If host_line doesn't contain domain, append domain
    if [[ "$host_line" != *.* ]]; then
      fqdn="${host_line}.${domain}"
    else
      fqdn="$host_line"
    fi

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
echo "_dmarc.${domain}. IN TXT \"v=DMARC1; p=none; rua=mailto:postmaster@${domain}; ruf=mailto:postmaster@${domain}; pct=100\""
echo
echo "Change p=none to p=quarantine or p=reject only after you validate SPF/DKIM and monitor reports."
echo "------------------------------------------------------------------"

echo
echo "✅ Setup complete. Postfix and OpenDKIM have been installed and started."
echo "✅ send.sh is running (or available) in tmux session: ${tmux_session}"
echo "To reattach: tmux attach -t ${tmux_session}"
echo "To stop sending, kill the tmux session: tmux kill-session -t ${tmux_session}"
echo
echo "Remember to publish the DKIM TXT, SPF, and DMARC records in your DNS for domain ${domain}."
echo "You can verify DKIM signing by sending a test email to a tester service (e.g., mailbox.org test, Gmail, or use tools like 'swaks' locally)."

exit 0
