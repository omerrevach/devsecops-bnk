# Deletes the project bank/bank and its release runner, so configure.rb can recreate them clean.
# Run by reset.sh (make demo-reset). Users, groups and instance settings stay.
admin = User.find_by_username!('root')
project = Project.find_by_full_path('bank/bank')
Projects::DestroyService.new(project, admin).execute if project
Ci::Runner.where(description: 'release-runner').find_each(&:destroy)
puts "bank/bank deleted: #{Project.find_by_full_path('bank/bank').nil?}"
