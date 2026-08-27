#!/usr/bin/env ruby
# frozen_string_literal: true

# Creates or updates the Extension + Exchange for this dashboard, and
# optionally triggers a Build.
#
# UNLIKE setup.sh, this is NOT a stable public API call -- Terminus has no
# REST API for Extensions or Exchanges at all (checked directly against its
# routes: app/actions/api/ has devices, models, playlists, screens, setup,
# display, log, firmware -- no extensions). This script instead calls the
# exact same internal repository/contract/job classes the web UI's own
# create actions do (app/actions/extensions/create.rb and
# app/actions/extensions/exchanges/create.rb), run inside the Terminus
# container via its own Ruby environment. That means real validation and
# the real scheduling side-effect run, same as clicking through the UI --
# but it depends on Terminus's internal class structure, which could change
# in a future release without notice. If it breaks after an upgrade, the
# UI steps in the main README always still work.
#
# Run inside the terminus-web container:
#   docker cp manage_extension.rb terminus-web-1:/tmp/manage_extension.rb
#   docker exec terminus-web-1 bash -c \
#     'cd /app && bundle exec ruby /tmp/manage_extension.rb'
#
# Configure via environment variables (all required except INTERVAL/UNIT):
#   EXTENSION_NAME, EXTENSION_LABEL, TEMPLATE_FILE, EXCHANGE_URL,
#   INTERVAL (default 2), UNIT (default "hour"), BUILD_MODEL_ID (optional --
#   triggers a build for this model id once the extension/exchange are set)

require "hanami/boot"

extension_name = ENV.fetch("EXTENSION_NAME")
extension_label = ENV.fetch("EXTENSION_LABEL", extension_name)
template_file = ENV.fetch("TEMPLATE_FILE")
exchange_url = ENV.fetch("EXCHANGE_URL")
interval = Integer(ENV.fetch("INTERVAL", "2"))
unit = ENV.fetch("UNIT", "hour")
build_model_id = ENV["BUILD_MODEL_ID"]

extension_repo = Hanami.app["repositories.extension"]
exchange_repo = Hanami.app["repositories.extension_exchange"]
schedule = Hanami.app["aspects.jobs.schedule"]
template_content = File.read(template_file)

existing = extension_repo.all.find { it.name == extension_name }

# start_at anchors the schedule's own timing -- deliberately NOT included in
# the shared attributes below, so re-running this to update e.g. just the
# template can never silently reset an already-running schedule's anchor.
# Only a genuine first-time creation sets it, to "now".
attributes = {
  name: extension_name,
  label: extension_label,
  description: nil,
  kind: "poll",
  tags: [],
  static_body: {},
  template: template_content,
  fields: [],
  data: {},
  interval:,
  unit:,
  days: [],
  last_day_of_month: false
}

if existing
  puts "Existing schedule: every #{existing.interval} #{existing.unit}(s)."
  puts "New schedule:      every #{interval} #{unit}(s)."
  extension_repo.update(existing.id, attributes.except(:name))
  extension = extension_repo.find(existing.id)
  puts "Updated extension #{extension.id} (#{extension_name})."
else
  extension = extension_repo.create_with_models(attributes.merge(start_at: Time.now), [])
  puts "Created extension #{extension.id} (#{extension_name})."
end

schedule.upsert(*extension.to_schedule)
puts "Schedule set: every #{interval} #{unit}(s)."

existing_exchange = exchange_repo.all.find { it.extension_id == extension.id }
if existing_exchange
  exchange_repo.update(existing_exchange.id, template: exchange_url, verb: "get")
  puts "Updated exchange #{existing_exchange.id} -> #{exchange_url}"
else
  exchange = exchange_repo.create(extension_id: extension.id, template: exchange_url, verb: "get")
  puts "Created exchange #{exchange.id} -> #{exchange_url}"
end

if build_model_id
  Terminus::Jobs::Extensions::Screen.new.perform(extension.id, Integer(build_model_id), nil)
  puts "Enqueued a build for model #{build_model_id}."
end

puts "Extension id: #{extension.id}"
