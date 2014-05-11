# == Schema Information
#
# Table name: raw_mails
#
#  content  :text(2147483647) default(""), not null
#  email_id :integer          not null
#  id       :integer          not null, primary key
#

class RawMail < ActiveRecord::Base
  attr_accessible :content, :email_id
  belongs_to :email
  has_one :user, through: :email

  validate :email, presence: true, uniqueness: true
  validate :content, presence: true

  def to_mail
    @mail ||= Mail.read_from_string content
  end

  def self.create_from_email_and_mail! email, mail
    begin # Hacky workaround for mail.to_s sometimes not working on multipart
      mail.parts.each {|part| part.to_s } if mail.multipart?
    rescue Exception => exception
      UnexpectedStateNotification.add nil, "Trouble during to_s workaround: #{exception.message}"
    end
    RawMail.create! email_id: email.id, content: mail.to_s
  end

end
