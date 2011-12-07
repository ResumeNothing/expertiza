class AssignmentTeam < Team
  
  belongs_to  :assignment, :class_name => 'Assignment', :foreign_key => 'parent_id'
  has_many    :review_mappings, :class_name => 'TeamReviewResponseMap', :foreign_key => 'reviewee_id'
  has_many    :responses, :finder_sql => 'SELECT r.* FROM responses r, response_maps m, teams t WHERE r.map_id = m.id AND m.type = \'TeamReviewResponseMap\' AND m.reviewee_id = t.id AND t.id = #{id}'

# START of contributor methods, shared with AssignmentParticipant

  # Whether this team includes a given participant or not
  def includes?(participant)
    return participants.include?(participant)
  end

  def assign_reviewer(reviewer)
    TeamReviewResponseMap.create(:reviewee_id => self.id, :reviewer_id => reviewer.id,
      :reviewed_object_id => assignment.id)
  end

  # Evaluates whether any contribution by this team was reviewed by reviewer
  # @param[in] reviewer AssignmentParticipant object 
  def reviewed_by?(reviewer)
    return TeamReviewResponseMap.count(:conditions => ['reviewee_id = ? AND reviewer_id = ? AND reviewed_object_id = ?', 
                                       self.id, reviewer.id, assignment.id]) > 0
  end

  # Topic picked by the team
  def topic
    team_topic = nil

    participants.each do |participant|
      team_topic = participant.topic
      break if team_topic
    end

    team_topic
  end

  # Whether the team has submitted work or not
  def has_submissions?
    participants.each do |participant|
      return true if participant.has_submissions?
    end
    return false
  end

  def reviewed_contributor?(contributor)
    return TeamReviewResponseMap.find(:all, 
      :conditions => ['reviewee_id = ? AND reviewer_id = ? AND reviewed_object_id = ?', 
      contributor.id, self.id, assignment.id]).empty? == false
  end

# END of contributor methods

  def participants
    @participants ||= AssignmentParticipant.find(:all, :conditions => ['parent_id = ? and user_id IN (?)', parent_id, users])
  end

  def delete
    if read_attribute(:type) == 'AssignmentTeam'
      signup = SignedUpUser.find_team_participants(parent_id.to_s).select{|p| p.creator_id == self.id}
      signup.each &:destroy
    end

    super
  end
  
  def self.get_first_member(team_id)
    participant = nil
    begin
      team = Team.find(team_id)
      user_id = team.teams_users.first.user_id
      participant = Participant.find_by_user_id_and_parent_id(user_id,team.parent_id)
    rescue NoMethodError => e
      puts "Ignoring error: #{e}"
    rescue ActiveRecord::RecordNotFound => e
      puts "Ignoring error: #{e}"
    end
    return participant
  end
 
  def get_hyperlinks
    links = Array.new
    for team_member in self.get_participants 
      links.concat(team_member.get_hyperlinks_array)
    end
    return links
  end
  
  def get_path
    self.get_participants.first.get_path
  end
  
  def get_submitted_files
    self.get_participants.first.get_submitted_files
  end
  
  def get_review_map_type
    return 'TeamReviewResponseMap'
  end  
  
  def self.import(row,session,id,options)
    if (row.length < 2 and options[:has_column_names] == "true") or (row.length < 1 and options[:has_column_names] != "true")
       raise ArgumentError, "Not enough items" 
    end
        
    if Assignment.find(id) == nil
      raise ImportError, "The assignment with id \""+id.to_s+"\" was not found. <a href='/assignment/new'>Create</a> this assignment?"
    end
    
    if options[:has_column_names] == "true"
        name = row[0].to_s.strip
        index = 1
    else
        name = generate_team_name()
        index = 0
    end 
    
    currTeam = AssignmentTeam.find(:first, :conditions => ["name =? and parent_id =?",name,id])
    
    if options[:handle_dups] == "ignore" && currTeam != nil
      return
    end
    
    if currTeam != nil && options[:handle_dups] == "rename"
       name = generate_team_name()
       currTeam = nil
    end
    if options[:handle_dups] == "replace" && teams.first != nil        
       for teamsuser in TeamsUser.find(:all, :conditions => ["team_id =?", currTeam.id])
           teamsuser.destroy
       end    
       currTeam.destroy
       currTeam = nil
    end     
    
    if currTeam == nil
       currTeam = AssignmentTeam.create(:name => name, :parent_id => id)
       parent = AssignmentNode.find_by_node_object_id(id)
       TeamNode.create(:parent_id => parent.id, :node_object_id => currTeam.id)
    end
      
    while(index < row.length) 
        user = User.find_by_name(row[index].to_s.strip)
        if user == nil
          raise ImportError, "The user \""+row[index].to_s.strip+"\" was not found. <a href='/users/new'>Create</a> this user?"                           
        elsif currTeam != nil         
          currUser = TeamsUser.find(:first, :conditions => ["team_id =? and user_id =?", currTeam.id,user.id])          
          if currUser == nil
            currTeam.add_member(user)            
          end                      
        end
        index = index+1      
    end                
  end

  def email
    self.get_team_users.first.email    
  end

  def get_participant_type
    "AssignmentParticipant"
  end  
 
  def get_parent_model
    "Assignment"
  end
  
  def fullname
    self.name
  end
  
  def get_participants 
    users = self.users        
    participants = Array.new
    users.each{
      | user | 
      participant = AssignmentParticipant.find_by_user_id_and_parent_id(user.id,self.parent_id)
      if participant != nil
        participants << participant
      end
    }
    return participants    
  end

  def copy(course_id)
   new_team = CourseTeam.create({:name => self.name, :parent_id => course_id})    
   copy_members(new_team)
  end
 
  def add_participant(assignment_id, user)
   if AssignmentParticipant.find_by_parent_id_and_user_id(assignment_id, user.id) == nil
     AssignmentParticipant.create(:parent_id => assignment_id, :user_id => user.id, :permission_granted => user.master_permission_granted)
   end    
  end
 
  def assignment
    Assignment.find(self.parent_id)
  end
 
  # return a hash of scores that the team has received for the questions
  def get_scores(questions)
    scores = Hash.new
    scores[:team] = self # This doesn't appear to be used anywhere
    assignment.questionnaires.each do |questionnaire|
      scores[questionnaire.symbol] = Hash.new
      scores[questionnaire.symbol][:assessments] = Response.all(:joins => :map,
        :conditions => {:response_maps => {:reviewee_id => self.id, :type => 'TeamReviewResponseMap'}})
      scores[questionnaire.symbol][:scores] = Score.compute_scores(scores[questionnaire.symbol][:assessments], questions[questionnaire.symbol])        
    end
    scores[:total_score] = assignment.compute_total_score(scores)
    return scores
  end
  
  def self.get_team(participant)
    team = nil
    teams_users = TeamsUser.find_all_by_user_id(participant.user_id)
    teams_users.each {
      | tuser |
      fteam = Team.find(:first, :conditions => ['parent_id = ? and id = ?',participant.parent_id,tuser.team_id])
      if fteam
        team = fteam
      end      
    }
    team  
  end

  # Get non-deduped list of past teammate user ids
  def get_past_teammate_user_ids(participant)
    past_team_associations = TeamsUser.find_all_by_user_id(participant.user_id)
    past_team_associations -= TeamsUser.find_all_by_team_id(id)
    past_team_association_team_ids = past_team_associations.map{|association| association.team_id}
    past_team_association_team_ids.delete_if {|team_id| Assignment.find_by_id(Team.find_by_id(team_id).parent_id).course_id != Assignment.find_by_id(parent_id).course_id}
    past_teammates = TeamsUser.find_all_by_team_id(past_team_association_team_ids)
    return past_teammates.map{|teammate| teammate.user_id}
  end

  # Get total number of past teammate possibilities
  def get_max_past_teammates(participant)
    past_team_associations = TeamsUser.find_all_by_user_id(participant.user_id)
    past_team_associations -= TeamsUser.find_all_by_team_id(id)
    past_team_ids = past_team_associations.map{|association| association.team_id}
    past_teams = past_team_ids.map{|team_id| Team.find_by_id(team_id)}
    past_assignments = past_teams.map{|team| Assignment.find_by_id(team.parent_id)}
    past_assignments.delete_if {|assignment| assignment.course_id != Assignment.find_by_id(parent_id).course_id}
    return past_assignments.inject(0) {|sum, assignment| sum += assignment.team_count - 1}
  end

# Get the number of pairing opportunities
  def get_pairing_opportunities
    course_assignments = assignment.course.assignments
    team_assignments = course_assignments.find_all {|assignment| assignment.team_assignment}
    pairing_opportunities = team_assignments.inject(0) {|sum, team| sum += team.team_count}
    return pairing_opportunities - team_assignments.length
  end

  # Determine if there is a pairing conflict or not
  def get_pairing_conflict(participant)

    # Check if maximum duplicate pairings has been exceeded
    max_duplicate_pairings = assignment.course.max_duplicate_pairings
    if max_duplicate_pairings != nil

      # Get past teammate user ids.
      past_teammate_ids = get_past_teammate_user_ids(participant)

      # Check against user id of each participant already in team
      participants.each do |current_participant|
        unique_teammate_ids = past_teammate_ids - [current_participant.user_id]
        if past_teammate_ids.length - unique_teammate_ids.length >= max_duplicate_pairings
          return TeamConflict.new(current_participant, participant, :max_duplicate_pairings, max_duplicate_pairings)
        end
      end

    end

    # Check if minimum unique pairings can still be met
    min_unique_pairings = assignment.course.min_unique_pairings
    if min_unique_pairings != nil

      # Get maximum number of past pairing opportunities
      max_past_teammates = get_max_past_teammates(participant)

      # Get maximum number of duplicate pairings for the course
      max_course_duplicate_pairings = get_pairing_opportunities - min_unique_pairings

      # Check if each participant can meet minimum unique pairings
      all_participants = participants + [participant]
      all_participants.each do |other_participant|
        past_teammate_ids = get_past_teammate_user_ids(other_participant)
        unique_teammate_ids = past_teammate_ids + all_participants.map {|part| part.user_id}
        unique_teammate_ids.uniq!
        unique_teammate_ids -= [other_participant.user_id]
        if max_past_teammates - unique_teammate_ids.length + participants.length > max_course_duplicate_pairings
          return TeamConflict.new(other_participant, participant, :min_unique_pairings, min_unique_pairings)
        end
      end

    end

    # No conflicts
    return nil

  end

end

