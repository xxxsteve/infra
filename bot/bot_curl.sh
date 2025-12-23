# Telegram
curl -X POST https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage \
  -H 'Content-type: application/json' \
  --data "{\"chat_id\":${TELEGRAM_CHAT_ID},\"text\":\"⚚ *ICON TRADING*\\nSharpe ratio over 3000\\!\",\"parse_mode\":\"Markdown\"}"

# Slack (webhook)
curl -X POST -H 'Content-type: application/json' \
  --data '{"text":"⚚ *ICON TRADING*\n Sharpe ratio over 3000!"}' \
  ${SLACK_WEBHOOK}

