# == Schema Information
#
# Table name: emails
#
#  id                     :integer          not null, primary key
#  type                   :string(255)      not null
#  to                     :string(255)      not null
#  from                   :string(255)      not null
#  subject                :string(255)
#  body_plaintext         :text             default(""), not null
#  email_id               :integer
#  template_id            :integer
#  contact_id             :integer          not null
#  in_reply_to_message_id :string(255)
#  delivery_status        :integer          default(0)
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  header_message_id      :string(255)      not null
#  sent_or_received_at    :datetime
#  read_at                :datetime
#  cc                     :string(255)
#  bcc                    :string(255)
#  uid                    :string(255)
#  thrid                  :string(255)
#  body_html              :text             default(""), not null
#  campaign_id            :integer          not null
#

class EmailIn < Email
  extend EmailFetched::EmailFetchedClass
  include EmailFetched::EmailFetchedInstance

  attr_accessible :in_reply_to_message_id, :read_at
  alias_attribute :received_at, :sent_or_received_at
  has_one :raw_mail, inverse_of: :email, foreign_key: :email_id, dependent: :destroy

  validates_presence_of :received_at
end
