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

# "Important" Notifications are shown to the user
IMPORTANT_NOTIFICATION_TYPES = %w(SpreadsheetSyncErrorNotification SpreadsheetSyncReportNotification SpreadsheetSyncingNotification ValueMissingTemplateNotification SpreadsheetUpdateGooglePushNotification RefreshCredentialsErrorNotification AllmailFolderUnavailableErrorNotification MessageFetchingNotification)
# "Activity" Notifications are ephemeral status displays which are also shown to the user.
ACTIVITY_NOTIFICATION_TYPES  = %w(ActivityNotification TemplateSentActivityNotification TemplateSentToSearchResultsActivityNotification)

class Notification < ActiveRecord::Base
  belongs_to :user
  attr_accessible :user, :message, :resource_id, :resource_type

  validates :user, presence: true
  validates :resource, presence: true, if: :should_have_resource?

  scope :important, where(type: IMPORTANT_NOTIFICATION_TYPES)
  scope :activities, where(type: ACTIVITY_NOTIFICATION_TYPES)
  scope :admin, where('notifications.type NOT IN (?)', ACTIVITY_NOTIFICATION_TYPES)
  scope :by_recency, order('notifications.created_at DESC')

  def self.for_record record
    where(resource_type: record.class.to_s, resource_id: record.id)
  end

  def self.similar_to notification
    where(user_id: notification.user.id, type: notification.type, message: notification.message.to_s, resource_type: notification.resource_type, resource_id: notification.resource_id)
  end

  def resource
    @resource ||= resource_class.find resource_id
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def resource_class
    resource_type.classify.constantize
  end

  def has_resource?
    should_have_resource? and resource.present?
  end

  def should_have_resource?
    resource_type.present? and resource_id.present?
  end

  def to_s
    "Notification <#{type}> for user #{user.id}: '#{message}'" + (has_resource? ? "on #{resource_type} #{resource_id}" : '')
  end

  protected

    def self.add *args
      raise 'This method should be overriden and create an instance of this Notification.'
    end

    def self.create_notification user, message, resource=nil
      user ||= User.with_role(:admin).first # for Notifications without a user
      self.create user: user, message: message, resource_id: resource.respond_to?(:id) ? resource.try(:id) : nil, resource_type: resource.respond_to?(:class) ? resource.try(:class).try(:to_s) : nil
    end

end
