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

# This class is for notifying of exceptions, or errors which aren't bound to a resource, or can't ever be considered "resolved".
# By our current understanding you'd never want to show one of these to a user.

class ExceptionNotification < Notification
  
  has_one :backtrace_object, class_name: 'Backtrace', dependent: :destroy
  
  validate :backtrace_object, associated: true

  def self.add user, exception, additional_message=nil
    message = exception.message
    message += additional_message if additional_message.present?
    subject = exception.subject if exception.respond_to?(:subject)
    notification = self.create_notification user, message, subject
    Backtrace.create!(content: exception.backtrace.join("\n"), exception_notification: notification)
  end
  
  def backtrace
    backtrace_object.content
  end

end
