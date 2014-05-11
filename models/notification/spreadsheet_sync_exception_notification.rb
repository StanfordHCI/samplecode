# == Schema Information
#
# Table name: notifications
#
#  id            :integer          not null, primary key
#  type          :string(255)      not null
#  resource_id   :integer
#  message       :text
#  user_id       :integer          not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  resource_type :string(255)
#

class SpreadsheetSyncExceptionNotification < ExceptionNotification
  
  def self.add spreadsheet, exception, additional_message=nil
    message = exception.message
    message += additional_message if additional_message.present?
    subject = spreadsheet
    notification = self.create_notification spreadsheet.user, message, subject
    Backtrace.create!(content: exception.backtrace.join("\n"), exception_notification: notification)
  end

end
