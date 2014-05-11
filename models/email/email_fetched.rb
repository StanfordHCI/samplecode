module EmailFetched

  module EmailFetchedClass

    def create_from_mail! mail_with_metadata
      mail = mail_with_metadata[:mail]
      email = self.create! do |email|
        email.to = mail[:to].to_s
        email.from = mail[:from].to_s
        email.subject = mail.subject
        email.sent_or_received_at = mail.date
        email.header_message_id = mail.message_id
        email.delivery_status = 0
        email.uid = mail_with_metadata[:uid]
        email.thrid = mail_with_metadata[:thrid]
        email.body_html, email.body_plaintext = mail.html_and_plaintext_body

        if email.is_a?(EmailDsn)
          email.in_reply_to_email = EmailDsn.detect_original_email mail
        else
          # Check whether the fetched email is in reply to something we know (normal case)
          email.in_reply_to_email = Email.find_by_header_message_id(mail.in_reply_to)
          # If not, check if we know any email in the whole reference chain (header field "references")
          email.in_reply_to_email ||= email.newest_known_ancestor mail
        end
        if email.in_reply_to_email.present?
          email.in_reply_to_message_id = mail.in_reply_to
          # Try to detect the campaign based on this email's in_reply_to
          email.campaign = email.in_reply_to_email.campaign
        end
        # Try to detect the campaign based on this email's labels
        email.campaign ||= email.identify_campaign_by_labels mail_with_metadata[:labels]
        # If we were unable to identify the campaign, we cannot import this email
        raise "Campaign was not found" if email.campaign.blank?

        if email.in_reply_to_email.present?
          email.contact = email.in_reply_to_email.contact
        else
          email.contact = email.identify_or_create_contact mail
        end

      end # self.create!
      
      begin
        mail.attachments.each do |attachment|
          EmailAttachment.create_from_email_and_attachment! email, attachment
        end
        mail.without_attachments!
        RawMail.create_from_email_and_mail! email, mail
      rescue Exception => exception
        email.destroy
        UnexpectedStateNotification.add nil, "Couldn't process an email addressed at #{mail[:to].to_s}, header_message_id: #{mail.message_id}"
      end
      email
    end # create_from_mail!

  end # EmailFetchedClass

  module EmailFetchedInstance

    def identify_campaign_by_labels labels
      labels = labels.select {|label| label =~ /^myriad\// } if labels.present?
      slug = labels.first.sub(/^myriad\//, "") if labels.any?
      raise "Campaign was not found" if slug.blank?
      Campaign.where(slug: slug).first
    end

    def identify_or_create_contact mail
      # Find or create contact
      contact_info = { user:          campaign.user,
                       email_address: self.incoming? ? mail.from.first : mail.to.first,
                       first_name:    self.incoming? ? mail[:from].addrs.first.try(:first_name) : mail[:to].addrs.first.try(:first_name),
                       last_name:     self.incoming? ? mail[:from].addrs.first.try(:last_name)  : mail[:to].addrs.first.try(:last_name)}

      contact = Contact.find_or_new_or_update contact_info
      # Add contact to campaign in order to create conversation etc.
      campaign.contacts << contact unless campaign.contacts.include? contact
      contact
    end

    def newest_known_ancestor mail
      return if mail.references.blank?
      mail.references = Array.wrap mail.references
      ancestors = []
      # For each header_message_id included in the mail's references,
      # check whether we know the corresponding email.
      mail.references.each do |ref|
        new_ancestor = Email.find_by_header_message_id(ref)
        ancestors << new_ancestor if new_ancestor.present?
      end
      # Sort the resulting emails by id (ASC)
      ancestors.sort_by {|ancestor| ancestor.id }
        # Return email with highest id (assumed to be the most recent one)
      ancestors.last
    end

    def to_mail
      if self.raw_mail
        @mail ||= self.raw_mail.to_mail
      else
        UnexpectedStateNotification.add self.user, "Couldn't create 'to_mail' for email #{self.id}", self
        nil
      end
    end

  end # EmailFetchedInstance

end # EmailFetched