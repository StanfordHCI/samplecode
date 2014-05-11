# == Schema Information
#
# Table name: templates_contacts
#
#  template_id :integer          not null
#  contact_id :integer          not null
#

# THIS SHOULD BE MERGED INTO EMAIL!!!

class TemplatesContact < ActiveRecord::Base
  self.primary_keys = :template_id, :contact_id
  
  belongs_to :template
  belongs_to :contact
end

# THIS SHOULD BE MERGED INTO EMAIL!!!