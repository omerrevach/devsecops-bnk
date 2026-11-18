# GitLab settings, users, groups, project, CI variables and runners for the lab.
# Run by configure.sh through `gitlab-rails runner`. Safe to run again: it creates only what is
# missing and re-applies every setting. Secrets come in as environment variables from configure.sh;
# new secrets (runner and access tokens) go out through the file in SECRETS_FILE, never to stdout.

ADMIN = User.find_by_username!('root')
PROJECT_PREFIX = ENV.fetch('PROJECT')
SECRETS = {}
ORG_ID = Organizations::Organization.first.id
PRIVATE = Gitlab::VisibilityLevel::PRIVATE

# Services return either the object or a ServiceResponse, depending on the GitLab version.
def created(response, key)
  record = response.respond_to?(:payload) ? response.payload[key] : response
  raise "#{key}: #{response.respond_to?(:message) ? response.message : record&.errors&.full_messages}" unless record&.persisted?

  record
end

def password_for(username)
  ENV.fetch("PASSWORD_#{username.tr('-', '_').upcase}")
end

# 1. Instance settings: no self sign-up, no Auto DevOps, and the package registry serves only packages
#    we uploaded ourselves (no forwarding to pypi.org, npmjs or Maven Central).
ApplicationSettings::UpdateService.new(ApplicationSetting.current, ADMIN, {
  signup_enabled: false,
  auto_devops_enabled: false,
  pypi_package_requests_forwarding: false,
  npm_package_requests_forwarding: false,
  maven_package_requests_forwarding: false,
  usage_ping_enabled: false
}).execute
puts 'settings: sign-up off, Auto DevOps off, package forwarding off'

# 2. Root password: set once, on the first run (configure.sh passes it only then).
if ENV['PASSWORD_ROOT']
  ADMIN.update!(password: ENV['PASSWORD_ROOT'], password_confirmation: ENV['PASSWORD_ROOT'],
                password_automatically_set: false)
  puts 'root: password set'
end

# 3. Users: the developer, and the Security approver.
users = { 'omeriko' => 'Omer (developer)', 'security-lead' => 'Security Lead' }.to_h do |username, name|
  user = User.find_by_username(username) || created(Users::CreateService.new(ADMIN, {
    name: name, username: username, email: "#{username}@lab.internal",
    password: password_for(username), password_confirmation: password_for(username),
    skip_confirmation: true, organization_id: ORG_ID
  }).execute, :user)
  puts "user: #{username}"
  [username, user]
end

# 4. Groups: "bank", and "bank/security" whose members approve and merge security changes.
bank = Group.find_by_full_path('bank') || created(Groups::CreateService.new(ADMIN, {
  name: 'bank', path: 'bank', visibility_level: PRIVATE, organization_id: ORG_ID
}).execute, :group)

security = Group.find_by_full_path('bank/security') || created(Groups::CreateService.new(ADMIN, {
  name: 'security', path: 'security', parent_id: bank.id, visibility_level: PRIVATE, organization_id: ORG_ID
}).execute, :group)
security.add_member(users['security-lead'], Gitlab::Access::OWNER)

# Every new project in "bank": nobody pushes to the default branch, only Maintainers merge into it,
# no force pushes. The first import is done by a Maintainer (platform/gitlab/push.sh).
bank.namespace_settings.update!(default_branch_protection_defaults: {
  allowed_to_push: [{ access_level: Gitlab::Access::NO_ACCESS }],
  allowed_to_merge: [{ access_level: Gitlab::Access::MAINTAINER }],
  allow_force_push: false,
  developer_can_initial_push: false
})
puts 'groups: bank, bank/security (security-lead = Owner); main: no pushes, Maintainers merge'

# 5. Project "bank/bank": developer = Developer (cannot merge to main), Security = Maintainer (can).
project = Project.find_by_full_path('bank/bank') || created(Projects::CreateService.new(ADMIN, {
  name: 'bank', path: 'bank', namespace_id: bank.id, visibility_level: PRIVATE,
  initialize_with_readme: false, organization_id: ORG_ID
}).execute, :project)

project.update!(only_allow_merge_if_pipeline_succeeds: true,
                only_allow_merge_if_all_discussions_are_resolved: true)
project.add_member(users['omeriko'], Gitlab::Access::DEVELOPER)
unless project.project_group_links.exists?(group: security)
  Projects::GroupLinks::CreateService.new(project, security, ADMIN, { link_group_access: Gitlab::Access::MAINTAINER }).execute
end
raise 'bank/security is not linked to the project' unless project.project_group_links.exists?(group: security)

puts "project: bank/bank (id #{project.id}); merge needs a green pipeline and resolved threads"

# 6. CI/CD variables. Robot names contain "$", so every value is raw (no variable expansion).
#    The release robot is protected: it exists only in pipelines on protected branches (main),
#    so merge-request code can never push to Harbor's release project.
{
  'HARBOR_CI_USER' => ['robot$ci-build', false, false],
  'HARBOR_CI_TOKEN' => [ENV.fetch('HARBOR_CI_TOKEN'), false, true],
  'HARBOR_RELEASE_USER' => ['robot$ci-release', true, false],
  'HARBOR_RELEASE_TOKEN' => [ENV.fetch('HARBOR_RELEASE_TOKEN'), true, true],
  'COSIGN_KEY' => ["awskms:///alias/#{PROJECT_PREFIX}-release-signing", false, false]
}.each do |key, (value, protected, masked)|
  project.variables.find_or_initialize_by(key: key, environment_scope: '*')
         .update!(value: value, protected: protected, masked: masked, raw: true)
end
puts 'ci variables: Harbor robots (release one protected), COSIGN_KEY'

# 7. Runners. The build runner takes every job tagged "build". The release runner belongs to this
#    project only and is protected: it runs jobs from protected branches (main) and nothing else.
def runner(description, params)
  Ci::Runner.find_by(description: description) || created(Ci::Runners::CreateRunnerService.new(
    user: ADMIN, params: params.merge(description: description, run_untagged: false)
  ).execute, :runner)
end
build_runner = runner('build-runner', runner_type: 'instance_type', tag_list: ['build'])
release_runner = runner('release-runner', runner_type: 'project_type', scope: project, tag_list: ['release'],
                                          access_level: 'ref_protected', locked: true)
SECRETS['runner-token-build'] = build_runner.token
SECRETS['runner-token-release'] = release_runner.token
puts 'runners: build-runner (tag build), release-runner (tag release, protected, this project only)'

# 8. API tokens for the scripted demo (push, merge request, approval). Replaced on every run.
%w[omeriko security-lead].each do |username|
  user = users[username]
  user.personal_access_tokens.active.where(name: 'lab-automation').each(&:revoke!)
  token = created(PersonalAccessTokens::CreateService.new(
    current_user: user, target_user: user, organization_id: ORG_ID,
    params: { name: 'lab-automation', scopes: [:api], expires_at: 30.days.from_now }
  ).execute, :personal_access_token)
  SECRETS["token-#{username}"] = token.token
end
puts 'tokens: omeriko, security-lead (scope api, 30 days)'

# 9. A read-only project token for the exception-approvals job: it reads merge requests and their approvals
#    to prove each exception was approved by Security. Replaced on every run; created by a Maintainer.
project.bots.each { |bot| bot.personal_access_tokens.active.where(name: 'exception-audit').each(&:revoke!) }
audit = created(ResourceAccessTokens::CreateService.new(users['security-lead'], project, {
  name: 'exception-audit', scopes: [:read_api], access_level: Gitlab::Access::REPORTER,
  expires_at: 30.days.from_now.to_date
}).execute, :access_token)
project.variables.find_or_initialize_by(key: 'GITLAB_AUDIT_TOKEN', environment_scope: '*')
       .update!(value: audit.token, protected: true, masked: true, raw: true)
puts 'audit token: read_api, protected CI variable GITLAB_AUDIT_TOKEN'

File.write(ENV.fetch('SECRETS_FILE'), SECRETS.map { |name, value| "#{name} #{value}" }.join("\n") + "\n")
