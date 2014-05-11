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

class EmailOut < Email
  alias_attribute :sent_at, :sent_or_received_at

  def to_mail
    if in_reply_to_email.present?
      # #reply sets in_reply_to, references, and also **subject**.
      mail = self.in_reply_to_email.to_mail.reply
    else
      mail = Mail.new
      mail.subject = subject
      if in_reply_to_message_id.present? # This is used to trick gmail's threading.
        mail.in_reply_to = in_reply_to_message_id.bracketed_message_id
        mail.references = in_reply_to_message_id.bracketed_message_id
      end
    end

    plaintext = body_plaintext
    mail.text_part do |part|
      
      part.body = plaintext
    end

    html = body_html
    mail.html_part do |part|
      part.content_type = 'text/html; charset=UTF-8'
      part.body         = html
    end

    # Set customized fields, like body or message_id
    mail.message_id = header_message_id.bracketed_message_id
    mail.from       = from
    mail.to         = to
    mail.cc         = cc
    mail.bcc        = bcc

    return mail
  end

end
