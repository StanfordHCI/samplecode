class Ability
  include CanCan::Ability

  def initialize user
    user ||= User.new # guest user (not logged in)
    
    # Admins rule.
    if user.has_role? :admin
      can :manage, :all
      can :manage, Resque
    end
    
    # Simple verifications that can be done on an object level:
    # https://github.com/ryanb/cancan/wiki/defining-abilities
    
    can :create, :all # Without this, some resources could not be created and later on assigned to the current_user.
    can :manage, User,         :id      => user.id
    can :manage, Contact,      :user_id => user.id
    can :manage, Notification, :user_id => user.id
    can :manage, EmailAddress, :user_id => user.id
    
    # Complicated verifications that use our authorize_user_for_resource method:
    # https://github.com/ryanb/cancan/wiki/Defining-Abilities-with-Blocks
    
    authorization_lambda = lambda { |resource| authorize_user_for_resource user, resource }
    
    can :manage, Campaign, &authorization_lambda
    can :manage, Template, &authorization_lambda
    can :manage, Conversation, &authorization_lambda
    can :manage, Key, &authorization_lambda
    can :manage, Search, &authorization_lambda
    can :manage, Spreadsheet, &authorization_lambda
    can :manage, AssistantAssignment, &authorization_lambda
    can :show,   EmailAttachment, &authorization_lambda
    
  end # initialize
  
  def authorize_user_for_resource user, resource
    campaign = resource.campaign
    campaign.nil? or campaign.user == user or campaign.assistants.include? user
  end

end # class Ability
