# coding: utf-8

class ContestsController < ApplicationController

  before_filter :privileged_user, :only => [:edit, :update, :new, :create, :destroy, :refresh, :realrank]
  before_filter :correct_time, :only => [:show]

  #caches_page :ranklist

  def index
    @title = '比赛列表'
    @contests = Contest.all
  end

  def show
    #@contest = Contest.find(params[:id])
  end

  def new
    @contest = Contest.new
  end

  def edit
    expire_page :action => 'ranklist'
    @contest = Contest.find(params[:id])
  end

  def create
    @contest = Contest.new(params[:contest])
    if @contest.save
      redirect_to @contest, :notice => '创建成功'
    else
      redirect_to 'new', :notice => '创建失败'
    end
  end

  def update
    @contest = Contest.find(params[:id])
    if @contest.update_attributes(params[:contest])
      redirect_to(@contest, :notice => 'Contest was successfully updated.') 
    else
      render :action => "edit" 
    end
  end

  def destroy
    @contest = Contest.find(params[:id])
    @contest.destroy
  end

  def ranklist
    @title = '比赛排名'
    @contest = Contest.find(params[:id])
    contest_id = @contest.id

    # times
    frozen, final, has_not_judged, @comment = false, false, false, ''
    from_time = @contest.start_time.to_datetime
    till_time = if Time.now > @contest.end_time
                  @comment << 'using final till_time; '
                  final = true
                  @contest.end_time.to_datetime
                elsif @contest.freeze_time and Time.now > @contest.freeze_time
                  @comment << 'using frozen till_time; '
                  frozen = true
                  @contest.freeze_time.to_datetime
                else
                  @comment << "#{@contest.end_time} greater than #{Time.now}; "
                  # return 0.8 minutes ago
                  @comment << 'using normal till_time; '
                  DateTime.now - 0.8 / 1400.0
                end

    if fragment_exist?({:action => 'ranklist', :id => contest_id, :controller => 'contests' })
      # should let it expires?
      last_update = $ranklist_last_updates[contest_id]
      if last_update.nil? or (till_time - last_update).abs > 2 / 1440.0 or (final and last_update < till_time)
        @comment << 'refreshed cache; '
        expire_fragment({:action => 'ranklist', :id => contest_id, :controller => 'contests' })
      else
        @comment << 'using cache; '
        return
      end
    end

    # mark last update time (till_time)
    $ranklist_last_updates[contest_id] = till_time

    # UserCache
    # filter problems
    problem_filters, user_filters = {}, {}
    @problems = {}
    ProblemLink.find(:all, :conditions => { :contest_id => @contest.id }).each do |link|
      problem_filters[link.problem_id] = true
      @problems[link.problem_id] = link.name
    end

    # collect contestants
    ranking = {}
    # TODO : use other string match (include ?)
    User.find(:all, 
              :conditions => { :group => @contest.visible_group }, 
              :select => 'id, nick').each do |u|
      id = u.id
      ranking[id] = UserRank.new(id, "#{u.nick}")
    end

    # consider submissions at that time and update ranking
    Submission.find(:all, 
                    :conditions => {:created_at => from_time..till_time}, 
                    :order => 'created_at ASC').each do |s|
      if problem_filters[s.problem_id]
        has_not_judged = true if s.result <= 1
        rank = ranking[s.user_id]
        rank.update(s, from_time) unless rank.nil?
      end
    end

    # set cache as invalid if has not judged
    $ranklist_last_updates[contest_id] = nil if has_not_judged
    
    # pass @variables to view
    @comment << (has_not_judged ? 'has not judged; ' : 'all judged; ')
    @problems = @problems.sort_by { |k, v| v }
    @rank = (ranking.sort_by { |k, v| v }).reverse
    @update_time = "#{till_time.strftime '%Y-%m-%d %H:%M:%S'} #{'(排名已经冻结，此页面显示的不是最新排名)' if frozen and not has_not_judged}"
    @update_time << "(比赛已经结束。#{has_not_judged == false ? '此页面内容为最终排名' : '尚有评测结果未确定，请稍候'})" if final
  end

  # clean cache
  def refresh
    id = params[:id]
    $ranklist_last_updates[id.to_s] = nil
    $ranklist_last_updates[id.to_i] = nil
    flash[:notice] = 'Refreshed'
    redirect_to :action => 'ranklist', :id => id
  end

  # real rank for admin
  def realrank
    @title = 'Realtime Ranklist'
    @contest = Contest.find(params[:id])
    contest_id = @contest.id

    # times
    frozen, final, has_not_judged, @comment = false, false, false, ''
    from_time = @contest.start_time.to_datetime
    till_time = if Time.now > @contest.end_time
                  final = true
                  @contest.end_time.to_datetime
                else
                  # return 0.8 minutes ago
                  DateTime.now - 0.1 / 1400.0
                end

    # UserCache
    # filter problems
    problem_filters, user_filters = {}, {}
    @problems = {}
    ProblemLink.find(:all, :conditions => { :contest_id => @contest.id }).each do |link|
      problem_filters[link.problem_id] = true
      @problems[link.problem_id] = link.name
    end

    # collect contestants
    ranking = {}
    # TODO : use other string match (include ?)
    User.find(:all, 
              :conditions => { :group => @contest.visible_group }, 
              :select => 'id, name').each do |u|
      id = u.id
      ranking[id] = UserRank.new(id, u.name)
    end

    # consider submissions at that time and update ranking
    # TODO : check created_at order works !
    Submission.find(:all, 
                    :conditions => {:created_at => from_time..till_time}, 
                    :order => 'created_at ASC').each do |s|
      if problem_filters[s.problem_id]
        has_not_judged = true if s.result <= 1
        rank = ranking[s.user_id]
        rank.update(s, from_time) unless rank.nil?
      end
    end

    # pass @variables to view
    @problems = @problems.sort_by { |k, v| v }
    @rank = (ranking.sort_by { |k, v| v }).reverse
    @update_time = "#{till_time.strftime '%Y-%m-%d %H:%M:%S'} #{'(还有提交在评测中)' if has_not_judged}"
  end

  private

  class UserRank
    # for judge_accepted? and judge_rejected?
    include SubmissionsHelper

    # attr_accessor can not be written twice in one class
    attr_accessor :problem_attempts, :problem_solved, :penalty, :solved, :user_id, :user_name

    def initialize(id, nick = nil)
      @problem_attempts, @problem_solved, @penalty, @solved  = {}, {}, 0.0, 0 
      @user_id, @user_name = id, (nick or id.to_s)
    end

    def <=>(y)
      return 1 if solved > y.solved
      return -1 if solved < y.solved
      # solved == y.solved
      return 1 if penalty < y.penalty
      return -1 if penalty > y.penalty
      return 0
    end

    def update(submit, contest_start_time)
      problem_id, stat = submit.problem_id, submit.result
      return if problem_solved[problem_id] # already ac
      if judge_accepted? stat
        # Datetime - returns days, not seconds. 1 day = 1440 minutes
        solved_at = (submit.created_at.to_datetime - contest_start_time) * 1440.0
        @problem_solved[problem_id] = solved_at
        @penalty += solved_at
        @penalty += (problem_attempts[problem_id] or 0) * 20.0
        @solved += 1
      elsif judge_rejected? stat
        @problem_attempts[problem_id] ||= 0
        @problem_attempts[problem_id] += 1
      end
    end
  end

  def correct_time
    @contest = Contest.find(params[:id])
    if Time.now < @contest.start_time 
      if is_admin?
        flash.now[:notice] = '该比赛尚未开始'
        return
      end
      redirect_to contests_path, :flash => { :error => '现在还没有到比赛时间' }
    end
  end

  def privileged_user
    if params[:id]
      return if Contest.find(params[:id]).moderate_by?(current_user)
    end
    return if is_admin?
    redirect_to root_path, :flash => { :error => '您无权限访问该页' }
  end
end
