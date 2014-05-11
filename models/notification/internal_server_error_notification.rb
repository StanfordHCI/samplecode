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

class InternalServerErrorNotification < ExceptionNotification

end
