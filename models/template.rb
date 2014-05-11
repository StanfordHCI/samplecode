# == Schema Information
#
# Table name: templates
#
#  id               :integer          not null, primary key
#  title            :string(255)
#  subject_template :string(255)
#  body_template    :text
#  campaign_id      :integer          not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  slug             :string(255)
#  emails_count     :integer          default(0)
#  cc               :string(255)      default(""), not null
#  bcc              :string(255)      default(""), not null
#  parent_id        :integer
#

class ValueMissingError < StandardError

  attr_accessor :placeholder, :contact, :template

  def initialize contact, template, msg = nil
    @contact = contact
    @template = template
    @msg = msg
  end

  def to_s
    error_msg = "Template didn't provide at least one value for contact: <b>#{@contact.display_name}</b> for template: <b>#{@template.title}</b>. Template:"
    if @msg.present?
      error_msg += "<ul>"
      error_msg += @msg
      error_msg += "</ul>"
    end

    error_msg
  end
end

class Template < ActiveRecord::Base
  extend FriendlyId
  include ActionView::Helpers::TextHelper
  friendly_id :title, use: :slugged

  attr_accessible :body_template, :subject_template, :title, :to, :cc, :bcc, :value_setting_actions_attributes
  attr_accessor :to, :added_contacts_count

  has_one  :user, through: :campaign
  belongs_to :campaign
  belongs_to :parent, class_name: :Template, foreign_key: :parent_id, inverse_of: :children
  has_many :children, class_name: :Template, foreign_key: :parent_id, inverse_of: :parent
  has_many :searches, autosave: true, inverse_of: :template
  has_many :templates_contacts, dependent: :destroy
  has_many :contacts, through: :templates_contacts
  has_many :emails, dependent: :destroy
  has_many :value_setting_actions, dependent: :destroy
  accepts_nested_attributes_for :value_setting_actions, allow_destroy: true

  validates :campaign_id     , presence:        true
  validates :campaign        , associated:      true
  validates :parent          , associated:      true, allow_nil: true
  validates :subject_template, presence:        true
  validates :body_template   , presence:        true
  validates :title           , presence:        true, uniqueness: { scope: 'campaign_id' }
  validates :to              , address_list:    true
  validates :value_setting_actions, associated: true
  validate  :value_setting_actions_keys_uniqueness
  validate  :provides_values_for_all_placeholders?, if: Proc.new { |template| template.dependent_attributes_valid? :to }

  scope :by_recency, order('templates.created_at DESC')
  scope :roots, where(parent_id: nil).order('created_at ASC')

  before_save :create_contacts
  before_save :associate_new_contacts_with_campaign
  after_save  :create_emails
  
  def conversations
    campaign.conversations.where("contact_id IN (?)", contacts)
  end

  def to= to
    @to = to.squish # remove remaining newlines
  end
  
  def response_rate
    emails.sent.select {|e| e.replies.incoming.any? }.count.to_f / emails.sent.count.to_f
  end
  
  # This fixes redactor's *stupid* div/p misbehavior by replacing all divs with p tags
  def body_template= html
    markup = Nokogiri::HTML::DocumentFragment.parse html
    markup.css('div').each { |element| element.name = 'p' }
    write_attribute :body_template, markup.to_html
  end

  def sent_notice
    if self.added_contacts_count <  contacts.count
      "Sending your message to #{ ActionController::Base.helpers.pluralize(self.added_contacts_count, 'contact') } out of #{ ActionController::Base.helpers.pluralize(contacts_from_to_field.count, 'contact') }. The rest had already received the message."
    elsif self.added_contacts_count == contacts.count
      "Sending your message to #{ ActionController::Base.helpers.pluralize(self.added_contacts_count, 'contact') }."
    end
  end
  
  def self.default_body_template
    'Hi '+"first_name".double_bracketize+',<br /> <br />' + "quoted_text".double_bracketize
  end

  def create_contacts
    added_contacts = contacts_from_to_field - contacts
    added_contacts.each { |new_contact| contacts << new_contact }
    self.added_contacts_count = added_contacts.count
  end
  
  def associate_new_contacts_with_campaign
    new_contacts = contacts - campaign.contacts
    new_contacts.each { |contact| contact.campaigns << campaign rescue ActiveRecord::RecordNotUnique }
  end # ActiveRecord::RecordNotUnique wraps a Mysql2::Error, which could happen if we insert a pre-existing entry into conversations.

  def update_parent_id
    emails.created.replies.each do |email|
      next if email.in_reply_to_email.nil?
      parent_template = find_parent_template email
      if parent_template != self and created_at > parent_template.created_at
        update_column :parent_id, parent_template.id and return
      end
    end
  end

  def find_parent_template email
    if email.in_reply_to_email.template.nil?
      find_parent_template email.in_reply_to_email
    else
      return email.in_reply_to_email.template
    end
  end

  def descendants
    children + children.flat_map(&:descendants) # flat_map = .map(...).flatten
  end

  def url_for_tree
    Rails.application.routes.url_helpers.use_template_campaign_templates_path(campaign, temp_id: id)
  end

  def add_unique_rule search  
    # check if rule already exists
    exists = false
    unless search.nil?
      self.searches.each do |f|
        if f.attributes.except('created_at','updated_at','id','template_id') == search.attributes.except('created_at','updated_at','id','template_id') and f.template_id == self.id and f.keys = search.keys and (search.key_bindings.map(&:value_content) & f.key_bindings.map(&:value_content)).size == search.key_bindings.size
          exists = true
          break
        end  
      end 
    end 

    if exists
      search.destroy
    else
      self.searches << search if search
    end 
  end 

  protected

    def create_emails
      self.reload # make sure we've got the newest version of ourself from db. necessary?
      new_contacts = contacts - emails.outgoing.map(&:contact)
      return unless new_contacts.any?
      Contact.transaction do # So that one email creation that blows up doesn't leave the db in an inconsistent state
        new_contacts.each do |contact|
          create_email_for contact
        end
      end
      Resque.enqueue(MessageSender, user.id)
      update_parent_id if self.parent_id.nil? # Do not modify existing IDs
    end

    def create_email_for contact, save = true
      email = EmailOut.new do |email|
        email.delivery_status = Email::DELIVERY_STATUSES.created # sets delivery status
        email.from = campaign.user.name_and_send_from_email_address
        email.to = contact.name_and_email_address
        email.cc = self.cc
        email.bcc = self.bcc
        email.contact = contact
        email.template = self
        email.header_message_id = campaign.create_message_identifier
        email.in_reply_to_email = contact.conversation_for_campaign(campaign).emails.latest
        
        # In order to fool Gmail's threading,
        # set in_reply_to_message_id to the id of the first email of this template.
        if email.in_reply_to_email.nil? and emails.first.present?
          email.in_reply_to_message_id = emails.first.header_message_id
        end
        
        if email.in_reply_to_email.nil? # else the reply method takes care of the Re: ... stuff
          email.subject = personalize email, :subject
        end
        
        email.body_html      = personalize email, :html
        email.body_plaintext = personalize email, :plaintext
        
        if campaign.user.always_bcc_self? # This is a hacky workaround to get email into your gmail inbox even when sending them externally
          email.bcc = [email.bcc, campaign.user.name_and_send_from_email_address].compact.join(', ')
        end
      end # EmailOut.new
      email.save! if save
      self.reload if emails.blank? and self.id.present? # this makes sure emails other than the first can access the first email
    end # create_email_for

    def personalize email, type = :plaintext
      case type
      when :html
        text = body_template
      when :plaintext
        text = Maildown.from_html body_template
      when :subject
        text = subject_template
      end
      
      personalized_text = text.gsub(/\{\{(.*?)\}\}/) do # $1 is the found placeholder, without the brackets
        replace email, $1, type
      end # instantiate TextTemplate
      if errors.messages[:body_template].present?
        more_errors = ""
        errors.messages[:body_template].each do |error|
          more_errors += '<li>'+error.split("for contact")[0]+'</li>'
        end
        raise ValueMissingError.new email.contact, self, more_errors
      end
      personalized_text
    end # personalize
    
    def replace email, placeholder, type = :plaintext
      if placeholder.similar_to? :first_name
        return email.contact.first_name
      elsif placeholder.similar_to? :last_name
        return email.contact.last_name
      elsif placeholder.similar_to? :quoted_text
        return (type == :html) ? email.quoted_html : email.quoted_text
      end
      campaign.keys.each do |key|
        if placeholder.similar_to? key.name
          proposed = email.contact.value_for_key key
          return proposed if proposed.present?
          errors.add :body_template, "contains #{placeholder.double_bracketize}, for which no value was found for contact #{email.contact.display_name}." and return
        end
      end # campaign.keys.each
      errors.add :body_template, "contains #{placeholder.double_bracketize}, for which no replacement options could be found."
    end
    
    # This is used to make validations dependant on each other.
    # Here, for example, we need valid contacts for testing whether we can replace their placeholders,
    # so we need to validate the to field before validating :provides_values_for_all_placeholders?
    def dependent_attributes_valid? *dependent_attributes
      dependent_attributes.each do |field|
        return false if self.errors.messages[field].present?
        self.class.validators_on(field).each { |validator| validator.validate(self) }
        return false if self.errors.messages[field].present?
      end
      return true
    end
    
    def value_setting_actions_keys_uniqueness
      keys = value_setting_actions.reject(&:marked_for_destruction?).map(&:key)
      errors.add :value_setting_actions, "contain duplicates!" if keys.contains_duplicates?
    end
    
    def contacts_from_to_field
      @contacts_from_to_field ||= Mail::AddressList.new(EmailAddress.encode_if_needed(@to)).addresses.map do |address|
        contact_info = { user: campaign.user,
                         email_address: address.address,
                         first_name:    address.first_name,
                         last_name:     address.last_name }
        Contact.find_or_new_or_update contact_info
      end
    end
    
    def provides_values_for_all_placeholders?
      # fake creating new emails
      contacts_from_to_field.each do |contact|
        EmailOut.new do |email|
          email.contact      = contact
          email.template       = self
          email.subject        = personalize email, :subject
          email.body_html      = personalize email, :html
          email.body_plaintext = personalize email, :plaintext
        end rescue nil
      end # contacts.each
    end # values_for_all_placeholders

end # class Template
