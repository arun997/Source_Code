#-- encoding: UTF-8
#-- copyright
# OpenProject is a project management system.
# Copyright (C) 2012-2015 the OpenProject Foundation (OPF)
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License version 3.
#
# OpenProject is a fork of ChiliProject, which is a fork of Redmine. The copyright follows:
# Copyright (C) 2006-2013 Jean-Philippe Lang
# Copyright (C) 2010-2013 the ChiliProject Team
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
#
# See doc/COPYRIGHT.rdoc for more details.
#++

require 'open_project/repository_authentication'

class SysController < ActionController::Base
  before_filter :check_enabled
  before_filter :require_basic_auth, only: [:repo_auth]
  before_filter :find_project, only: [:update_required_storage]
  before_filter :find_repository_with_storage, only: [:update_required_storage]

  def projects
    p = Project.active.has_module(:repository)
        .includes(:repository)
        .references(:repositories)
        .order('identifier')
    respond_to do |format|
      format.json do
        render json: p.to_json(include: :repository)
      end
      format.any(:html, :xml) do
        render xml: p.to_xml(include: :repository), content_type: Mime::XML
      end
    end
  end

  def create_project_repository
    project = Project.find(params[:id])
    if project.repository
      render nothing: true, status: 409
    else
      logger.info "Repository for #{project.name} was reported to be created by #{request.remote_ip}."
      service = Scm::RepositoryFactoryService.new(project, params)

      if service.build_and_save
        project.repository = service.repository
        render xml: project.repository, status: 201
      else
        render nothing: true, status: 422
      end
    end
  end

  def update_required_storage
    result = update_storage_information(@repository, params[:force] == '1')
    render text: "Updated: #{result}", status: 200
  end

  def fetch_changesets
    projects = []
    if params[:id]
      projects << Project.active.has_module(:repository).find_by!(identifier: params[:id])
    else
      projects = Project.active.has_module(:repository)
                 .includes(:repository).references(:repositories)
    end
    projects.each do |project|
      if project.repository
        project.repository.fetch_changesets
      end
    end
    render nothing: true, status: 200
  rescue ActiveRecord::RecordNotFound
    render nothing: true, status: 404
  end

  def repo_auth
    project = Project.find_by(identifier: params[:repository])
    if project && authorized?(project, @authenticated_user)
      render text: 'Access granted'
    else
      render text: 'Not allowed', status: 403 # default to deny
    end
  end

  private

  def authorized?(project, user)
    repository = project.repository

    if repository
      policy = repository.class.authorization_policy
      policy.new(project, user).authorized?(params)
    else
      false
    end
  end

  def check_enabled
    User.current = nil
    unless Setting.sys_api_enabled? && params[:key].to_s == Setting.sys_api_key
      render text: 'Access denied. Repository management WS is disabled or key is invalid.', status: 403
      return false
    end
  end

  def update_storage_information(repository, force = false)
    if force
      Delayed::Job.enqueue ::Scm::StorageUpdaterJob.new(repository)
      true
    else
      repository.update_required_storage
    end
  end

  def find_project
    @project = Project.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render text: "Could not find project ##{params[:id]}.", status: 404
  end

  def find_repository_with_storage
    @repository = @project.repository

    if @repository.nil?
      render text: "Project ##{@project.id} does not have a repository.", status: 404
    else
      return true if @repository.scm.storage_available?
      render text: 'repositories.storage.not_available', status: 400
    end

    false
  end

  def require_basic_auth
    authenticate_with_http_basic do |username, password|
      @authenticated_user = cached_user_login(username, password)
      return true if @authenticated_user
    end

    response.headers['WWW-Authenticate'] = 'Basic realm="Repository Authentication"'
    render text: 'Authorization required', status: 401
    false
  end

  def user_login(username, password)
    User.try_to_login(username, password)
  end

  def cached_user_login(username, password)
    unless Setting.repository_authentication_caching_enabled?
      return user_login(username, password)
    end
    user = nil
    user_id = Rails.cache.fetch(OpenProject::RepositoryAuthentication::CACHE_PREFIX + Digest::SHA1.hexdigest("#{username}#{password}"),
                                expires_in: OpenProject::RepositoryAuthentication::CACHE_EXPIRES_AFTER) {
      user = user_login(username, password)
      user ? user.id.to_s : '-1'
    }

    return nil if user_id.blank? or user_id == '-1'

    user || User.find_by(id: user_id.to_i)
  end
end