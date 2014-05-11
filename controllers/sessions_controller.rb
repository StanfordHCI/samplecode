class SessionsController < ApplicationController
  
  skip_before_filter :authenticate_user!

  def new
    redirect_to '/auth/google_oauth2'
  end

  def create
    user = User.where(:provider => auth['provider'], :uid => auth['uid'].to_s).first || User.create_with_omniauth(auth)
    session[:user_id] = user.id

    # The deep_find methods recursively traverses hashes to find what you're looking for. No matter where it hides - or if the structure changes. :-)
    user.name                    = auth.deep_find 'name'                if auth.deep_find 'name'
    user.access_token            = auth.deep_find 'token'               if auth.deep_find 'token'
    user.refresh_token           = auth.deep_find 'refresh_token'       if auth.deep_find 'refresh_token'
    user.access_token_expires_at = Time.at(auth.deep_find 'expires_at') if auth.deep_find 'expires_at'
    user.save!

    Resque.enqueue(ContactSyncer, user.id) if user.created_at > Time.new - 1.minutes

    if user.email_address.blank?
      redirect_to edit_user_path(user), :alert => "Please enter your email address."
    else
      Resque.enqueue(MessageFetcher, user.id)
      redirect_to campaigns_path, :notice => 'Signed in!'
    end
  end

  def destroy
    reset_session
    redirect_to root_url, :notice => 'Signed out!'
  end

  def failure
    redirect_to root_url, :alert => "Authentication error: #{params[:message].humanize}"
  end

  def refresh
    SessionsController.refresh_access_token_for_user current_user
    redirect_to root_url, :notice => 'Retrying to authernticate with Google...'
  end

  def refresh_ajax
    SessionsController.refresh_access_token_for_user current_user

    render nothing: true
  end

  def self.refresh_access_token_for_user user
    begin
      if user.refresh_token.present?
        data = {
            :client_id => ENV['oauth_client_id'],
            :client_secret => ENV['oauth_client_secret'],
            :refresh_token => user.refresh_token,
            :grant_type => 'refresh_token'
        }
        response = ActiveSupport::JSON.decode(RestClient.post ENV['oauth_refresh_url'], data)
        if response['access_token'].present?
          user.access_token = response['access_token']
          user.access_token_expires_at = Time.now + response['expires_in'].seconds
          user.save!
          user.touch :access_token_updated_at
          RefreshCredentialsErrorNotification.resolve user
        else
          RefreshCredentialsErrorNotification.add user, "Didn't receive access_token for user #{user.display_name}: #{response}"
          Rails.logger.error "Didn't receive access_token for user #{user.display_name}: #{response}"
          return false
        end
      else
        UnexpectedStateNotification.add user, "Tried refreshing access token without having a refresh token. If you're a developer, try reauthorizing."
      end
    rescue Exception => exception
      RefreshCredentialsErrorNotification.add user, exception.message
      Rails.logger.error response.to_s
      return false
    end
  end

  protected

    def auth
      request.env['omniauth.auth']
    end



end

