set :output, "#{path}/log/cron.log"
Time.zone = "Pacific Time (US & Canada)"

every 15.minutes do
  runner "Spreadsheet.poll_all_spreadsheets"
end

every 1.hour do
  rake "backup:db"
end

every :day, at: Time.zone.parse('4:30 am') do
  rake "fetch:fetch_emails_for_all_users"
  rake "fetch:refetch_recent_missing_ids"
  rake "backup:attachments"
  rake "spreadsheet:renew_expiration_date"

  rake 'google:sync_contacts_for_all_users'

end

every :reboot do
  rake "resque:start_workers"
end