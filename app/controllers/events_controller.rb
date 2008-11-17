class EventsController < ApplicationController
  before_filter :check_edit_permissions, :only => [:new, :create, :destroy, :edit, :update, :email_list, :pull_from_children]
  
  def email_list
    @event = Event.find(params[:id])
  end
  
  def index
    @events = visible_events
  end
  
  def new
    @event = Event.new
    calculate_edit_vars
  end
  
  def create
    @event = Event.new(params[:event])
    if @context
      @event.parent = @context
    end
    save_from_form
  end
  
  def destroy
    @event = Event.find params[:id]
    if params[:sure]
      @event.destroy
      redirect_to events_url
    end
  end
  
  def show
    @event = Event.find params[:id]
  end
  
  def show_description
    @event = Event.find params[:id]
    @noninteractive = true
    render :action => "show"
  end
  
  def pull_from_children
    @event = Event.find params[:id]
    @event.pull_from_children
    redirect_to @event
  end
  
  def edit
    @event = Event.find params[:id]
    calculate_edit_vars
  end
  
  def update
    @event = Event.find params[:id]
    save_from_form
  end
  
  private
  def save_from_form
    if @event.new_record?
      @event.save
      @event.set_default_registration_policy
    end
    
    flash[:error_messages] ||= []
    
    locs = params[:event][:locations] || []
    @event.event_locations.each do |booking|
      if not locs.include? booking.location.id
        booking.destroy
      end
    end
    
    locs.each do |locid|
      loc = Location.find(locid)
      if not @event.locations.include? Location.find(locid)
        booking = EventLocation.new(:event => @event, :location => loc, :exclusive => true)
        if not booking.save
          flash[:error_messages].push("Could not add the location #{loc.name}: #{booking.errors.full_messages.join(", ")}")
        end
      end
    end
    
    if params[:remove_staff]
      params[:remove_staff].each_key do |staff_id|
        if params[:remove_staff][staff_id]
          @event.staff.delete Person.find(staff_id.to_i)
        end
      end
    end
    
    if params[:add_staff][:firstname].length > 0 or params[:add_staff][:lastname].length > 0
      results = Person.find :all, :conditions => ["firstname LIKE ? AND lastname LIKE ?", 
        "%#{params[:add_staff][:firstname]}%", "%#{params[:add_staff][:lastname]}%"]
      if results.length == 1
        a = Attendance.new :person => results[0], :event => @event, :is_staff => true, :counts => false
        if not a.save
          flash[:error_messages].push("Could not add the staff member specified: #{a.errors.full_messages.join(", ")}")
        end
      elsif results.length == 0
        flash[:error_messages].push("Couldn't find a person by the name specified.")
      else
        flash[:error_messages].push("Found multiple people by the name specified.  Please be more specific.")
      end
    end
    
    if params[:add_virtual_site][:domain].length > 0
      site_template_id = params[:add_virtual_site][:site_template]
      if site_template_id and site_template_id != ''
        site_template = SiteTemplate.find(site_template_id)
      end
      vs = @event.virtual_sites.new :domain => params[:add_virtual_site][:domain], :site_template => site_template
      if not vs.save
        flash[:error_messages].push("Couldn't create new VirtualSite: #{vs.errors.full_messages.join(", ")}")
      end
    end
    
    if params[:delete_virtual_site]
      params[:delete_virtual_site].each_key do |vs_id|
        if params[:delete_virtual_site][vs_id]
          VirtualSite.find(vs_id.to_i).destroy
        end
      end
    end
    
    if (params[:limited_capacity] and not (@event.kind_of? LimitedCapacityEvent))
      @event.type = "LimitedCapacityEvent"
      @event.save
      @event = Event.find(@event.id)
    elsif (not params[:limited_capacity] and (@event.kind_of? LimitedCapacityEvent))
      @event.type = "Event"
      @event.save
      @event = Event.find(@event.id)
    end
    
    if @event.kind_of? LimitedCapacityEvent and params[:limits]
      %w(male female neutral).each do |gender|
        slot = @event.attendee_slots.find_or_initialize_by_gender(gender)
        slot.update_attributes(params[:limits][gender])
        if not slot.save
          flash[:error_messages].push("Could not change #{gender} attendee limits: #{slot.errors.full_messages.join(", ")}")
        end
      end
    end
    
    policy = @event.obtain_registration_policy
    
    if not params[:registration_open]
      if not policy.contains_rule_type? ClosedEventRule
        ClosedEventRule.create :policy => policy
      end
    else
      policy.each_rule_of_type ClosedEventRule do |rule|
        rule.destroy
      end
    end
    
    if not params[:non_exclusive]
      if not policy.contains_rule_type? ExclusiveEventRule
        ExclusiveEventRule.create :policy => policy
      end
    else
      policy.each_rule_of_type ExclusiveEventRule do |rule|
        rule.destroy
      end
    end
    
    if params[:age_restricted]
      if not policy.contains_rule_type? AgeRestrictionRule
        AgeRestrictionRule.create :policy => policy
      end
      policy.reload
      policy.each_rule_of_type AgeRestrictionRule do |rule|
        rule.min_age = params[:min_age]
        rule.save
      end
    else
      policy.each_rule_of_type AgeRestrictionRule do |rule|
        rule.destroy
      end
    end
    
    if @event.update_attributes(params[:event]) and flash[:error_messages].length == 0
      redirect_to(event_url(@event))
    else
      redirect_to(edit_event_url(@event))
    end
  end
  
  def calculate_edit_vars
    @limited_capacity = @event.kind_of? LimitedCapacityEvent
    @limits = {}
    %w(male female neutral).each do |gender|
      @limits[gender] = {}
      slot = nil
      if @limited_capacity
        slot = @event.attendee_slots.find_by_gender(gender)
      end
      %w(min preferred max).each do |threshold|
        if slot.nil?
          limit = 0
        else
          limit = slot.send(threshold)
        end
        @limits[gender][threshold] = limit
      end
    end
    
    @registration_open = true
    @non_exclusive = true
    if @event.registration_policy
      @event.registration_policy.rules.each do |rule|
        if rule.kind_of? ClosedEventRule
          @registration_open = false
        end
        if rule.kind_of? ExclusiveEventRule
          @non_exclusive = false
        end
        if rule.kind_of? AgeRestrictionRule
          @age_restricted = true
          @min_age = rule.min_age
        end
      end
    end
  end
  
  def check_edit_permissions
    if params[:id] or @context
      event = Event.find params[:id] || @context
      if logged_in?
        person = logged_in_person
        if event.has_edit_permissions? person
          return
        end
      end
    else
      if logged_in?
        person = logged_in_person
        if person.permitted? nil, "edit_events"
          return
        end
      end
    end
    flash[:error_messages] = ["You aren't permitted to perform that action.  Please log into an account that has permissions to do that."]
    redirect_to events_url
  end
  
  def visible_events
    if @context
      return @context.children
    else
      return Event.find(:all)
    end
  end
end