# frozen_string_literal: true

#
# Copyright (C) 2013 - present Instructure, Inc.
#
# This file is part of Canvas.
#
# Canvas is free software: you can redistribute it and/or modify it under
# the terms of the GNU Affero General Public License as published by the Free
# Software Foundation, version 3 of the License.
#
# Canvas is distributed in the hope that it will be useful, but WITHOUT ANY
# WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR
# A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
# details.
#
# You should have received a copy of the GNU Affero General Public License along
# with this program. If not, see <http://www.gnu.org/licenses/>.
#

# @API Assignment Groups
class AssignmentGroupsApiController < ApplicationController
  before_action :require_context
  before_action :get_assignment_group, :except => [:create]

  include Api::V1::AssignmentGroup

  # @API Get an Assignment Group
  #
  # Returns the assignment group with the given id.
  #
  # @argument include[] ["assignments"|"discussion_topic"|"assignment_visibility"|"submission"|"score_statistics"]
  #   Associations to include with the group. "discussion_topic" and "assignment_visibility" and "submission"
  #   are only valid if "assignments" is also included. "score_statistics" is only valid if "submission" and
  #   "assignments" are also included. The "assignment_visibility" option additionally requires that the Differentiated Assignments
  #   course feature be turned on.
  #
  # @argument override_assignment_dates [Boolean]
  #   Apply assignment overrides for each assignment, defaults to true.
  #
  # @argument grading_period_id [Integer]
  #   The id of the grading period in which assignment groups are being requested
  #   (Requires grading periods to exist on the account)
  #
  # @returns AssignmentGroup
  def show
    if authorized_action(@assignment_group, @current_user, :read)
      includes = Array(params[:include])
      override_dates = value_to_boolean(params[:override_assignment_dates] || true)
      assignments = @assignment_group.visible_assignments(@current_user)
      if params[:grading_period_id].present?
        assignments = GradingPeriod.for(@context).find_by(id: params[:grading_period_id]).assignments(@context, assignments)
      end
      if assignments.any? && includes.include?('submission')
        submissions = submissions_hash(['submission'], assignments)
      end
      includes.delete('assignment_visibility') unless @context.grants_any_right?(@current_user, :read_as_admin, :manage_grades, *RoleOverride::GRANULAR_MANAGE_ASSIGNMENT_PERMISSIONS)
      render :json => assignment_group_json(@assignment_group, @current_user, session, includes, {
        stringify_json_ids: stringify_json_ids?,
        override_dates: override_dates,
        assignments: assignments,
        submissions: submissions
      })
    end
  end

  # @API Create an Assignment Group
  #
  # Create a new assignment group for this course.
  #
  # @argument name [String]
  #   The assignment group's name
  #
  # @argument position [Integer]
  #   The position of this assignment group in relation to the other assignment groups
  #
  # @argument group_weight [Float]
  #   The percent of the total grade that this assignment group represents
  #
  # @argument sis_source_id [String]
  #   The sis source id of the Assignment Group
  #
  # @argument integration_data [Object]
  #   The integration data of the Assignment Group
  #
  # @argument rules
  #   The grading rules that are applied within this assignment group
  #   See the Assignment Group object definition for format
  #
  # @returns AssignmentGroup
  def create
    @assignment_group = @context.assignment_groups.temp_record
    if authorized_action(@assignment_group, @current_user, :create)
      unless valid_integration_data?(params)
        return render :json => 'Invalid integration data', :status => :bad_request
      end

      updated = update_assignment_group(@assignment_group, params)
      process_assignment_group(updated)
    end
  end

  # @API Edit an Assignment Group
  #
  # Modify an existing Assignment Group.
  # Accepts the same parameters as Assignment Group creation
  #
  # @returns AssignmentGroup
  def update
    if authorized_action(@assignment_group, @current_user, :update)
      unless valid_integration_data?(params)
        return render :json => 'Invalid integration data', :status => :bad_request
      end

      updated = update_assignment_group(@assignment_group, params)
      unless can_update_assignment_group?(@assignment_group)
        return render_unauthorized_action
      end

      process_assignment_group(updated)
    end
  end

  # @API Destroy an Assignment Group
  #
  # Deletes the assignment group with the given id.
  #
  # @argument move_assignments_to [Integer]
  #   The ID of an active Assignment Group to which the assignments that are
  #   currently assigned to the destroyed Assignment Group will be assigned.
  #   NOTE: If this argument is not provided, any assignments in this Assignment
  #   Group will be deleted.
  #
  # @returns AssignmentGroup
  def destroy
    if authorized_action(@assignment_group, @current_user, :delete)

      if @assignment_group.assignments.active.exists?
        if @assignment_group.has_frozen_assignment_group_id_assignment?(@current_user)
          err_msg = t('errors.frozen_assignments_error', "You cannot delete a group with a locked assignment.")
          @assignment_group.errors.add('workflow_state', err_msg, :att_name => 'workflow_state')
          render :json => @assignment_group.errors, :status => :bad_request
          return
        end

        if params[:move_assignments_to]
          @assignment_group.move_assignments_to params[:move_assignments_to]
          recompute_student_scores
        end
      end

      @assignment_group.destroy
      render :json => assignment_group_json(@assignment_group, @current_user, session, [], { stringify_json_ids: stringify_json_ids? })
    end
  end

  def get_assignment_group
    @assignment_group = @context.assignment_groups.active.find(params[:assignment_group_id])
  end

  def process_assignment_group(updated)
    if updated && @assignment_group.save
      render :json => assignment_group_json(@assignment_group, @current_user, session, [], { stringify_json_ids: stringify_json_ids? })
    else
      render :json => @assignment_group.errors, :status => :bad_request
    end
  end

  def can_update_assignment_group?(assignment_group)
    return true if @context.account_membership_allows(@current_user)
    return true unless assignment_group.group_weight_changed? || assignment_group.rules_changed?
    !assignment_group.any_assignment_in_closed_grading_period?
  end

  private

  def valid_integration_data?(params)
    integration_data = params['integration_data']
    integration_data.is_a?(ActionController::Parameters) || integration_data.nil?
  end

  def recompute_student_scores
    @context.recompute_student_scores
  rescue
    nil
  end
end
