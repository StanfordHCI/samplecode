class IdFetcher < AbstractWorker

  @queue = self.queue_name

  RETRIES = 3

  # Requires used_id even though the user could be inferred from email_ids
  # This is to highlight the fact that this method can only be called for one user at a time
  def self.perform user_id, email_ids, number_of_tries, trigger_label_setter=false, time_period=0

    user = User.find(user_id)
    return if user.blank?

    if number_of_tries >= RETRIES
      FetchingExceptionNotification.add user, "Retried fetching ID for email IDs #{email_ids.to_s} #{RETRIES.to_s} times. I'm giving up. Please investigate."
      @logger.error "Retried fetching ID for email IDs #{email_ids.to_s} #{RETRIES.to_s} times. I'm giving up. Please investigate."
      return
    end

    sleep 10.seconds

    message_fetcher = Fetcher.new user.id, time_period
    message_fetcher.fetch_ids email_ids

    if trigger_label_setter
      email_ids.each do |email_id|
        Resque.enqueue(MessageLabelSetter, email_id, number_of_tries)
      end
    end
  end

end # class MessageFetcher
