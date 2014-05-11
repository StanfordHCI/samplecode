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

# This class is for notifying users or admins of errors. Those errors belong to a resource, and, after a retry for example, can become resolved.

class ErrorNotification < Notification

  validates :resource, presence: true

  def self.add resource, message=nil
    user = resource.user
    prior_notification = user.notifications.where(type: name, resource_id: resource.id).first
    if prior_notification.present?
      prior_notification.message = message # updates 'updated_at' to current time as
      prior_notification.save!
    else
      create_notification user, message, resource
    end
  end

  def self.resolve resource
    return unless resource.present? and resource.user.present?
    user = resource.user
    prior_notification = user.notifications.where(type: name, resource_id: resource.id).first
    prior_notification.destroy if prior_notification.present?
  end

end
