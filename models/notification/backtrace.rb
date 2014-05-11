class Backtrace < ActiveRecord::Base
  belongs_to :exception_notification
  
  attr_accessible :content, :exception_notification
  
  validate :exception_notification_id, present: true
  validate :content                  , present: true
end
