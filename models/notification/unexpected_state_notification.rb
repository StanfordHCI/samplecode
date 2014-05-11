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

class UnexpectedStateNotification < Notification

  def self.add user, message, resource=nil
    self.create_notification user, message, resource
  end

  # By *definition* an UnexpectedStateNotification doesn't have a resolve method.
  # If an unexpected state has occured, an admin *always* needs to acknowledge/delete it manually.

end
