#!/bin/bash
#
# Lightweight Postfix+OpenDKIM setup (NO TLS)
# Designed for environments without systemd (e.g. Cloud Shell)
#
# Run as root (sudo) — script will install packages and configure DKIM.
#

set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root or with sudo."
  exit 1
fi

# ---------- Configurable values ----------
myhostname="mail.admailsend.com"
mydomain="admailsend.com"
sender_name="EMAIL"
email_list="list.txt"
dkim_selector="mail"   # DKIM selector name (will create mail._domainkey)
# -----------------------------------------

echo "Updating package list and installing required packages..."
apt-get update -y
apt-get install -y postfix opendkim opendkim-tools mailutils tmux

# ---------- Backup existing Postfix config ----------
echo "Backing up existing Postfix configuration (if present)..."
if [ -f /etc/postfix/main.cf ]; then
  cp /etc/postfix/main.cf /etc/postfix/main.cf.backup.$(date +%s) || true
fi

# ---------- Write lightweight Postfix main.cf (no TLS) ----------
echo "Writing /etc/postfix/main.cf (lightweight, sendmail mode, NO TLS)..."

tee /etc/postfix/main.cf > /dev/null <<EOL
# Lightweight Postfix main.cf for sendmail submission (no systemd daemon assumption)
myhostname = ${myhostname}
mydomain = ${mydomain}
myorigin = /etc/mailname
mydestination = localhost
inet_interfaces = loopback-only
queue_directory = /var/spool/postfix
command_directory = /usr/sbin
daemon_directory = /usr/lib/postfix/sbin
mailbox_size_limit = 0
recipient_delimiter = +

# Do NOT configure TLS here (explicitly left out per request)

# OpenDKIM milter (socket location used below)
smtpd_milters = unix:/var/run/opendkim/opendkim.sock
non_smtpd_milters = unix:/var/run/opendkim/opendkim.sock
milter_default_action = accept
milter_protocol = 6

# Minimal compatibility settings (avoid old warnings)
compatibility_level = 3.6
EOL

# Ensure /etc/mailname contains domain used for myorigin
echo "${mydomain}" > /etc/mailname

# ---------- OpenDKIM configuration ----------
echo "Creating OpenDKIM directories and configuration..."
mkdir -p /etc/opendkim/keys/${mydomain}
chown -R opendkim:opendkim /etc/opendkim || true
chmod 750 /etc/opendkim || true

cat > /etc/opendkim.conf <<EOL
Syslog                  yes
UMask                   002
Socket                  local:/var/run/opendkim/opendkim.sock
PidFile                 /var/run/opendkim/opendkim.pid
Mode                    sv
Domain                  ${mydomain}
KeyFile                 /etc/opendkim/keys/${mydomain}/${dkim_selector}.private
Selector                ${dkim_selector}
Canonicalization        relaxed/simple
OversignHeaders         From
EOL

cat > /etc/opendkim/KeyTable <<EOL
${dkim_selector}._domainkey.${mydomain} ${mydomain}:${dkim_selector}:/etc/opendkim/keys/${mydomain}/${dkim_selector}.private
EOL

cat > /etc/opendkim/SigningTable <<EOL
*@${mydomain} ${dkim_selector}._domainkey.${mydomain}
EOL

cat > /etc/opendkim/TrustedHosts <<EOL
127.0.0.1
localhost
${myhostname}
EOL

# ---------- Generate DKIM key ----------
echo "Generating DKIM key (selector=${dkim_selector})..."
cd /etc/opendkim/keys/${mydomain}
# if key already exists, do not overwrite
if [ -f "${dkim_selector}.private" ]; then
  echo "DKIM key already exists, skipping generation."
else
  opendkim-genkey -s "${dkim_selector}" -d "${mydomain}"
  chown opendkim:opendkim "${dkim_selector}.private" "${dkim_selector}.txt"
  chmod 600 "${dkim_selector}.private"
fi

# ---------- Create socket directory and ensure permissions ----------
mkdir -p /var/run/opendkim
chown opendkim:opendkim /var/run/opendkim || true

# ---------- Start OpenDKIM manually (background) ----------
echo "Starting OpenDKIM in background (manual, no systemd)..."
# Kill any existing opendkim running in foreground to avoid duplicates
pkill -f "opendkim -x /etc/opendkim.conf" 2>/dev/null || true
# Start opendkim as the 'opendkim' user; keep it in background
sudo -u opendkim opendkim -x /etc/opendkim.conf -P /var/run/opendkim/opendkim.pid &

# ---------- Reload Postfix configuration (no systemctl) ----------
echo "Reloading Postfix configuration (postfix reload)..."
# postconf will warn if mail system not running; reload is safe for sendmail submission
postfix reload || true

# ---------- Create email content and send script ----------
echo "Creating email.html..."
cat > email.html <<'EOL'
Letter
EOL
chmod 664 email.html

echo "Creating send.sh (uses sendmail -t)..."
cat > send.sh <<'EOL'
#!/bin/bash
counter=1
while IFS= read -r email; do
  echo "Sending email to: $email"
  from_username="supportzed$counter"
  from_domain="admailsend.com"
  from_email="$from_username@$from_domain"
  from_name="EMAIL"
  from_header="$from_name <$from_email>"
  random_number=$(shuf -i 100-999 -n 1)
  subject="SECURE ! ($random_number)"
  subdomain=$(tr -dc 'a-z' </dev/urandom | head -c3)
  html_content=$(sed "s/{{EMAIL}}/$email/g; s/{{SUBDOMAIN}}/$subdomain/g" email.html)
  cat <<EOF | /usr/sbin/sendmail -t
To: $email
From: $from_header
Subject: $subject
MIME-Version: 1.0
Content-Type: text/html

$html_content
EOF
  ((counter++))
done < list.txt
EOL

chmod +x send.sh

# ---------- Create empty list.txt (you'll populate it) ----------
echo "Creating (empty) list.txt — please add recipient emails to this file."
cat > list.txt <<EOL
EOL

# ---------- Final notes & DNS records ----------
echo ""
echo "================ SETUP COMPLETE (lightweight, NO TLS) ================"
echo ""
echo "Important notes:"
echo " - This configuration does NOT use TLS. You requested TLS removed."
echo " - Postfix is configured for sendmail submission (inet_interfaces=loopback-only)."
echo " - OpenDKIM has been started in the background to sign outgoing messages."
echo " - Because systemd/queue managers are not required here, delivery behavior depends on"
echo "   the environment — messages may still be subject to provider/network constraints."
echo ""
echo "DKIM public record (publish this as a TXT record):"
echo "============================================================================"
echo "Host (NAME):    ${dkim_selector}._domainkey.${mydomain}"
echo "Type:           TXT"
echo -n "Value:          "
# print DKIM TXT content from generated .txt file
if [ -f /etc/opendkim/keys/${mydomain}/${dkim_selector}.txt ]; then
  awk '{printf "%s ", $0} END{print ""}' /etc/opendkim/keys/${mydomain}/${dkim_selector}.txt
else
  echo "<DKIM TXT file not found — key generation may have failed>"
fi
echo "============================================================================"
echo ""
echo "SPF record suggestion (publish as TXT for your domain):"
echo "  ${mydomain}. IN TXT \"v=spf1 mx ~all\""
echo ""
echo "DMARC record suggestion (publish as TXT for _dmarc.${mydomain}):"
echo "  _dmarc.${mydomain}. IN TXT \"v=DMARC1; p=quarantine; rua=mailto:postmaster@${mydomain}\""
echo ""
echo "To send: populate list.txt with recipient emails then run in tmux:"
echo "  tmux new-session -d -s mail_session './send.sh'"
echo "To check the postfix queue (may show 'mail system is down' if Postfix queue managers are not running):"
echo "  postqueue -p"
echo ""
echo "If you want OpenDKIM to persist across shell restarts, you'll need to re-run the 'sudo -u opendkim ... &' command or put it in a small supervisor script."
echo "======================================================================="
