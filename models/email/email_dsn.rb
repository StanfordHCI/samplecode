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

class EmailDsn < Email
  extend EmailFetched::EmailFetchedClass
  include EmailFetched::EmailFetchedInstance

  attr_accessible :read_at
  alias_attribute :received_at, :sent_or_received_at
  has_one :raw_mail, inverse_of: :email, foreign_key: :email_id, dependent: :destroy

  validates_presence_of :received_at

  def self.detect_original_email mail
    # Detect the email this notification is about
    begin
      original_email_msgid = mail.body.to_s.scan(/Message-ID: <(.*?)>/)[0][0]
    rescue
      raise "Parsing the DSN for its target message failed."
    end
    original_email = Email.find_by_header_message_id(original_email_msgid)

    # Check whether this is a Delivery Failure Notification (could be any other Delivery Status Notification)
    # If yes, mark corresponding email as failed
    if original_email.present? and mail.detect_bounce
      original_email.delivery_failed!
    else
      raise "The email this notification is referring to was not found."
    end

    return original_email
  end # self.detect_original_email
end
