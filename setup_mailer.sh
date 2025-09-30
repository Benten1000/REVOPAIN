#!/bin/bash

# ========================================
# Cloud Shell compatible Postfix setup
# with TLS + OpenDKIM for secure delivery
# ========================================

# Ensure root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root or with sudo."
  exit 1
fi

# === Predefined values ===
myhostname="mail.admailsend.com"
mydomain="admailsend.com"
sender_name="EMAIL"
email_list="list.txt"

# === Install packages ===
echo "Installing Postfix, OpenDKIM, mailutils, tmux..."
apt-get update -y
apt-get install -y postfix opendkim opendkim-tools mailutils tmux certbot

# === Obtain TLS certificate ===
echo "Obtaining Let's Encrypt certificate..."
certbot certonly --standalone -d $myhostname --non-interactive --agree-tos -m admin@$mydomain || {
  echo "⚠️ Certbot failed — ensure $myhostname DNS A record points here."
}

# === Backup Postfix main.cf ===
echo "Backing up Postfix config..."
cp /etc/postfix/main.cf /etc/postfix/main.cf.backup 2>/dev/null

# === Postfix configuration (sendmail mode) ===
tee /etc/postfix/main.cf > /dev/null <<EOL
myhostname = $myhostname
mydomain = $mydomain
myorigin = /etc/mailname
mydestination = localhost
inet_interfaces = loopback-only
queue_directory = /var/spool/postfix
command_directory = /usr/sbin
daemon_directory = /usr/lib/postfix/sbin
mailbox_size_limit = 0
recipient_delimiter = +

# Outbound TLS
smtp_tls_security_level = may
smtp_tls_loglevel = 1
smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt

# DKIM milter
smtpd_milters = unix:/var/run/opendkim/opendkim.sock
non_smtpd_milters = unix:/var/run/opendkim/opendkim.sock
milter_default_action = accept
milter_protocol = 6
EOL

# Ensure /etc/mailname exists
echo "$mydomain" > /etc/mailname

# ========================================
# OpenDKIM configuration
# ========================================
mkdir -p /etc/opendkim/keys/$mydomain
chown -R opendkim:opendkim /etc/opendkim
chmod 750 /etc/opendkim

# DKIM config file
cat > /etc/opendkim.conf <<EOL
Syslog                  yes
UMask                   002
Socket                  local:/var/run/opendkim/opendkim.sock
PidFile                 /var/run/opendkim/opendkim.pid
Mode                    sv
Domain                  $mydomain
KeyFile                 /etc/opendkim/keys/$mydomain/mail.private
Selector                mail
Canonicalization        relaxed/simple
OversignHeaders         From
TrustAnchorFile         /usr/share/dns/root.key
EOL

# KeyTable & SigningTable
cat > /etc/opendkim/KeyTable <<EOL
mail._domainkey.$mydomain $mydomain:mail:/etc/opendkim/keys/$mydomain/mail.private
EOL

cat > /etc/opendkim/SigningTable <<EOL
*@${mydomain} mail._domainkey.${mydomain}
EOL

cat > /etc/opendkim/TrustedHosts <<EOL
127.0.0.1
localhost
$myhostname
EOL

# Generate DKIM key
opendkim-genkey -D /etc/opendkim/keys/$mydomain/ -d $mydomain -s mail
chown opendkim:opendkim /etc/opendkim/keys/$mydomain/mail.private
chmod 600 /etc/opendkim/keys/$mydomain/mail.private

# Create socket directory
mkdir -p /var/run/opendkim
chown opendkim:opendkim /var/run/opendkim

# Start OpenDKIM manually in background
echo "Starting OpenDKIM..."
sudo -u opendkim opendkim -x /etc/opendkim.conf -P /var/run/opendkim/opendkim.pid &

# Reload Postfix to apply config
postfix reload

# ========================================
# Create email content and send script
# ========================================
echo "Creating email.html..."
cat > email.html <<EOL
Letter
EOL
chmod 664 email.html

echo "Creating send.sh..."
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

# Create list.txt
echo "Creating list.txt..."
cat > list.txt <<EOL
EOL

# ========================================
# DNS instructions for SPF/DKIM/DMARC
# ========================================
echo ""
echo "✅ Setup complete. Emails are sent via sendmail."
echo ""
echo "Add the following DNS records to improve inbox delivery:"
echo ""
echo "SPF:"
echo "$mydomain. IN TXT \"v=spf1 mx ~all\""
echo ""
echo "DKIM (selector: mail):"
cat /etc/opendkim/keys/$mydomain/mail.txt
echo ""
echo "DMARC:"
echo "_dmarc.$mydomain. IN TXT \"v=DMARC1; p=quarantine; rua=mailto:postmaster@$mydomain\""
echo ""
echo "PTR (reverse DNS):"
echo "Ensure your server IP resolves to $myhostname"
echo ""
echo "Start sending in tmux:"
echo "tmux new-session -d -s mail_session './send.sh'"
echo "To reattach: tmux attach -t mail_session"
