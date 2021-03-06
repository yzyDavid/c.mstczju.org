# coding: utf-8

class SubmissionsController < ApplicationController
  before_filter :privileged_user, :only => [:edit, :update, :destroy, :rejudge]
  before_filter :signed_in_user, :only => [:create, :new]
  before_filter :correct_view_source_user, :only => [:source]
  before_filter :correct_view_log_user, :only => [:log]

  # since submissions are will_paginated, it can not be cached directly

  def index
    @title = '最近提交'
    @submissions = Submission.paginate(:page => params[:page])
  end

  def show
    @submission = Submission.find(params[:id])
  end

  def new
    @title = '提交代码'
    @submission = Submission.new
  end

  def edit
    @submission = Submission.find(params[:id])
  end

  def rejudge
    @submission = Submission.find(params[:id])
    @submission.update_attributes!(:result => 0, :used_memory => nil, :used_time => nil)
    redirect_to :back
  end

  def create
    # reject quick submissions
    next_submit_limit = $next_submit_limits[current_user.id] || (Time.now - 1)
    $next_submit_limits.clear if $next_submit_limits.size >= 1024
    $next_submit_limits[current_user.id] = Time.now + 5 + rand(7)

    if Time.now < next_submit_limit
        redirect_to root_path, :flash => { :error => '提交过于频繁，请稍候再试' }
        return
    end

    # construct safe params
    submission_params = {
      :user_id => current_user.id,
      :problem_id => params[:submission][:problem_id],
      :lang => params[:submission][:lang],
      :code => params[:submission][:code],
      :result => 0,
    }

    # check problem_id time
    # not that Problem.find may cause error, use find_by_id instead
    permitted, now, problem = is_admin?, Time.now, Problem.find_by_id(submission_params[:problem_id])
    unless problem.nil?
      unless permitted
        problem.contests.each do |contest|
          if now >= contest.start_time and now <= contest.end_time
            permitted = true
            break
          end
        end
      end
      if not permitted
        redirect_to root_path, :flash => { :error => '目前时间不能提交该题目代码' }
        return
      end
      # else, submission model will validates problem's existance
    else
      redirect_to new_submission_path, :flash => { :error => '无效的题目ID' }
      return
    end

    submission_params[:result] = if is_admin?
                                   params[:submission][:result]
                                 else
                                   0
                                 end

    @submission = Submission.new(submission_params)

    if @submission.save
      redirect_to(@submission, :notice => '提交成功') 
    else
      render :action => "new" 
    end
  end

  def update
    # require admin, so no check here
    @submission = Submission.find(params[:id])

    if @submission.update_attributes(params[:submission])
      redirect_to(@submission, :notice => 'Submission was successfully updated.') 
    else
      render :action => "edit" 
    end
  end

  def destroy
    @submission = Submission.find(params[:id])
    @submission.destroy

    redirect_to(submissions_url)
  end

  def source
    @title = '源代码' 
  end

  def log
    @title = '详细信息'
  end

  private

  def privileged_user
    redirect_to root_path, :flash => { :error => '您无权访问该页' } unless is_admin?
  end

  def correct_view_source_user
    @submission = Submission.find(params[:id])
    redirect_to root_path, :flash => { :error => '您无权查看该提交代码' } unless @submission.owner?(current_user) || is_admin?
  end

  def correct_view_log_user
    @submission = Submission.find(params[:id])
    # here, 2 is COMPILE_ERROR
    unless @submission.has_additional_log? and ((@submission.owner?(current_user) and @submission.result == 2) or is_admin?)
      redirect_to root_path, :flash => { :error => '您无权查看该页面' } 
    end
  end

  def signed_in_user
    redirect_to root_path, :flash => { :error => '登录后才能访问该页' } unless signed_in?
  end
end
