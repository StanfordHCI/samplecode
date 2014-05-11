class SMTP
  def self.send mails, user
    mails = Array(mails) # make sure this is an array; encapsulate if not
    report = {} # this will contain delivery-status information

    begin
      # SMTP Authentication
      smtp = Net::SMTP.new('smtp.gmail.com', 587)
      smtp.enable_starttls_auto
      smtp.start('gmail.com', user.email_address, user.access_token, :xoauth2)

      # Go over all mails, send them, collect report
      mails.each_with_index do |mail, index|
        begin

          smtp.send_message(mail.to_s, user.email_address, mail.to)
          report[index] = false

        rescue Net::SMTPAuthenticationError => exception
          report[index] = exception
        rescue Net::SMTPServerBusy => exception
          report[index] = exception
        rescue Net::SMTPSyntaxError => exception
          report[index] = exception
        rescue Net::SMTPFatalError => exception
          report[index] = exception
        rescue Net::SMTPUnknownError => exception
          report[index] = exception
        rescue TimeoutError => exception
          report[index] = exception
        rescue IOError => exception
          report[index] = exception
        rescue Exception => exception
          report[index] = exception
        end
      end

    rescue Exception => exception
      report[:base] = exception
    end

    return report
  end

end
