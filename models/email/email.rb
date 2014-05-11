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

class Email < ActiveRecord::Base
  attr_accessible :from, :subject, :body_html, :body_plaintext, :to, :delivery_status, :header_message_id, :template_id, :sent_or_received_at, :email_id, :uid, :thrid
  belongs_to :campaign
  belongs_to :template, counter_cache: true
  belongs_to :contact,  counter_cache: true
  belongs_to :in_reply_to_email, class_name: :Email, foreign_key: :email_id
  has_many   :replies, class_name: :Email, foreign_key: :email_id
  has_one    :user, through: :campaign
  has_many   :attachments, class_name: :EmailAttachment, dependent: :destroy

  # Those statuses are a mess right now. Contact Ludwig who's responsible for this mess.
  enum_column :delivery_status, :DELIVERY_STATUSES, { scoped: true }, default: 0, created: 1, sending: 2, sent: 3, sending_failed: 4, delivery_failed: 5
  DS_ON_GMAIL = [DELIVERY_STATUSES.default, DELIVERY_STATUSES.sent, DELIVERY_STATUSES.delivery_failed]

  validates :type, :to, :from, :header_message_id, length: { maximum: 255 }, presence: true
  validates :subject, :delivery_status, :in_reply_to_message_id, length: { maximum: 255 }
  validates :contact_id, presence: true
  validates :contact, :template, associated: true
  validates :delivery_status, presence: true, inclusion: { in: (0...DELIVERY_STATUSES.delivery_failed).to_a}

  scope :unread,         where('emails.read_at IS NULL').where(type: :EmailIn)
  scope :unsent,         where('emails.sent_or_received_at IS NULL').where(delivery_status: DELIVERY_STATUSES.created, type: :EmailOut)
  scope :sending_failed, where('emails.sent_or_received_at IS NULL').where(delivery_status: DELIVERY_STATUSES.sending_failed, type: :EmailOut)
  scope :sent,           where('emails.sent_or_received_at IS NOT NULL').where(type: :EmailOut)
  scope :outgoing,       where(type: [:EmailOut, :EmailOutGmail])
  scope :incoming,       where(type: [:EmailIn, :EmailDsn])
  scope :created,        where(type: :EmailOut)
  scope :fetched,        where(type: [:EmailOutGmail, :EmailIn, :EmailDsn])
  scope :received,       where('emails.sent_or_received_at IS NOT NULL').where(type: [:EmailIn, :EmailDsn])
  scope :by_recency,     order('CASE WHEN emails.sent_or_received_at is NULL THEN emails.created_at ELSE emails.sent_or_received_at END DESC, emails.created_at DESC')
  scope :replies,        where('emails.email_id IS NOT NULL')
  scope :having_thrid,   where("thrid IS NOT NULL AND thrid != 'N/A'")
  scope :having_uid,     where("uid   IS NOT NULL AND uid   != 'N/A'")
  scope :on_gmail,       where(delivery_status: DS_ON_GMAIL)
  scope :missing_uid_or_thrid, on_gmail.where("uid = 'N/A' OR uid IS NULL OR thrid = 'N/A' OR thrid IS NULL")


  def body
    body_plaintext or body_html # TODO: look at every usage and determine what is appropriate
  end

  def self.latest
    by_recency.first
  end
  
  def conversation
    Conversation.find_by_campaign_and_contact campaign, contact
  end
  
  def incoming?
    is_a?(EmailIn) or is_a?(EmailDsn)
  end

  def outgoing?
    !incoming?
  end
  
  # Status-related actions
  
  delegate :default?, :created?, :sending?, :sent?, :sending_failed?, :delivery_failed?, to: :delivery_status

  # Don't just touch the timestamp - we need the callbacks to trigger conversation cache update
  def mark_read!
    self.read_at = Time.now
    self.save!
  end

  def created!
    update_attribute(:delivery_status, DELIVERY_STATUSES.created)
  end

  def sending!
    update_attribute(:delivery_status, DELIVERY_STATUSES.sending)
  end

  def sent!
    update_attribute(:delivery_status, DELIVERY_STATUSES.sent)
    update_attribute(:sent_or_received_at, Time.now)
    if !template.nil?
      template.value_setting_actions.each do |action|
        action.apply_to_contact contact
      end
    end
  end

  def sending_failed!
    update_attribute(:delivery_status, DELIVERY_STATUSES.sending_failed)
  end

  def delivery_failed!
    update_attribute(:delivery_status, DELIVERY_STATUSES.delivery_failed)
  end

  def status
    delivery_status.t
  end
  
  def retry_sending!
    raise "tried resending a non created email" unless self.is_a? EmailOut
    update_attribute(:delivery_status, DELIVERY_STATUSES.created)
    update_attribute(:sent_or_received_at, nil)
    Resque.enqueue(MessageSender, user.id)
  end
  
  # Other

  def human_friendly_status # Returns [type, msg], type is used in rendering.
   [:default, :default, :warning, :success, :error, :error][self.delivery_status]
  end

  def template= template
    write_attribute :template_id, template.try(:id)
    self.campaign = template.try(:campaign)
  end

  def campaign= campaign
    if template.present? and template.campaign != campaign
      raise "Template of email has different campaign than email itself"
    else
      write_attribute :campaign_id, campaign.try(:id)
    end
  end

  def from_name
    name_from_address = from.scan(/"([^"]*)"/).flatten.first || from.scan(/^[^<]*/).flatten.first
    if incoming?
      name_from_contact = contact.name
    else
      name_from_contact = campaign.user.name
    end
    name_from_address || name_from_contact
  end


  def from_email_address
    address_from_address = from.scan(/<([^<>]*)>/).flatten.first || from
    if incoming?
      address_from_contact = contact.email_address
    else
      address_from_contact = campaign.user.email_address
    end
    address_from_address || address_from_contact
  end

  def to_name
    name_from_address = to.scan(/"([^"]*)"/).flatten.first || to.scan(/^[^<]*/).flatten.first
    if incoming?
      name_from_contact = contact.name
    else
      name_from_contact = campaign.user.name
    end
    name_from_address || name_from_contact
  end

  def to_email_address
    address_from_address = to.scan(/<([^<>]*)>/).flatten.first || to
    if incoming?
      address_from_contact = contact.email_address
    else
      address_from_contact = campaign.user.email_address
    end
    address_from_address || address_from_contact
  end

  def quoted_text
    return '' unless self.in_reply_to_email.present? and self.in_reply_to_email.sent_or_received_at.present?
    quote_descriptor + self.in_reply_to_email.body_plaintext.split("\n").map{ |line| '> ' + line}.join("\n")
  end
  
  def quoted_html
    return '' unless self.in_reply_to_email.present? and self.in_reply_to_email.sent_or_received_at.present?
    ERB.render('layouts/email_html_quote', email: self)
  end

  def body_without_quoted_text
    MailExtract.new(body_plaintext).text
  end

  def body_quoted_text_only
    (MailExtract.new(body_plaintext).signature + "\n" + MailExtract.new(body_plaintext).quote).strip
  end

  def quote_descriptor
    'On ' + self.in_reply_to_email.sent_or_received_at.to_email_timestamp + ', ' + self.in_reply_to_email.from + ' wrote:' + "\n\n"
  end


  # Email fetching related maintenance (used in future rake task)

  def self.mark_unretrievable_ids ids_not_found, time_limit
    unretrievable_count = 0
    if !ids_not_found.blank?
      Email.where(header_message_id: ids_not_found).where("sent_or_received_at < ?", time_limit).each do |e|
        e.update_attributes(uid: "N/A", thrid: "N/A")
        unretrievable_count += 1
      end
    end
    return unretrievable_count
  end

  def self.update_uid_thrid_by_msgid uid, thrid, msgid
    # Skip element if not all required data is present (checks both for nil and empty as nil.to_s = "")
    return if msgid.to_s.empty? || thrid.to_s.empty? || uid.to_s.empty?
    Email.where(header_message_id: msgid).first.update_attributes(uid: uid, thrid: thrid)
  end

end
