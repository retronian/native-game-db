#!/usr/bin/env ruby
# frozen_string_literal: true

# Strip IGDB-derived content from every game entry.
#
# IGDB (Internet Game Database, owned by Twitch) data is governed by
# the Twitch Developer Services Agreement which forbids redistribution
# of "Program Materials or data as available from a Twitch API". The
# agreement only allows attribution-style references — not bulk
# republication of the API payload.
#
# This script removes:
#   - titles[] entries whose source is "igdb"
#   - descriptions[] entries whose source is "igdb" or "igdb_storyline"
#
# It keeps:
#   - external_ids.igdb    (a numeric identifier; that's a fact, not API content)
#   - everything from wikidata, wikipedia_*, romu, no_intro, manual,
#     gamelist_ja, skyscraper_ja, etc.
#
# Games that end up with zero titles[] left are reported but not
# auto-deleted; we want to eyeball that list first.
#
# Usage:
#   ruby scripts/purge_igdb_content.rb            # all platforms
#   ruby scripts/purge_igdb_content.rb --dry-run
#   ruby scripts/purge_igdb_content.rb --platform gb

require 'json'
require 'optparse'

$stdout.sync = true

ROOT = File.expand_path('..', __dir__)
SRC  = File.join(ROOT, 'data', 'games')

IGDB_TITLE_SOURCES = %w[igdb].freeze
IGDB_DESC_SOURCES  = %w[igdb igdb_storyline].freeze

def process_file(path, dry_run:)
  game = JSON.parse(File.read(path))
  before_titles = game['titles'].size
  before_descs  = (game['descriptions'] || []).size

  game['titles'] = game['titles'].reject { |t| IGDB_TITLE_SOURCES.include?(t['source']) }
  game['descriptions'] = (game['descriptions'] || []).reject { |d| IGDB_DESC_SOURCES.include?(d['source']) }
  game.delete('descriptions') if game['descriptions'].empty?

  removed_titles = before_titles - game['titles'].size
  removed_descs  = before_descs - (game['descriptions'] || []).size

  result = {
    titles_removed: removed_titles,
    descs_removed:  removed_descs,
    titles_left:    game['titles'].size
  }

  if removed_titles.positive? || removed_descs.positive?
    File.write(path, JSON.pretty_generate(game) + "\n") unless dry_run
  end

  result
end

def main
  options = { dry_run: false, platform: nil }
  OptionParser.new do |opts|
    opts.on('--dry-run') { options[:dry_run] = true }
    opts.on('--platform ID') { |p| options[:platform] = p }
  end.parse!

  glob = if options[:platform]
           File.join(SRC, options[:platform], '*.json')
         else
           File.join(SRC, '*', '*.json')
         end

  totals = Hash.new(0)
  empty_games = []

  Dir.glob(glob).sort.each do |path|
    res = process_file(path, dry_run: options[:dry_run])
    totals[:files] += 1
    totals[:titles_removed] += res[:titles_removed]
    totals[:descs_removed]  += res[:descs_removed]
    totals[:games_touched]  += 1 if res[:titles_removed].positive? || res[:descs_removed].positive?
    empty_games << path if res[:titles_left].zero?
  end

  puts '=== purge_igdb_content ==='
  totals.each { |k, v| puts "  #{k}: #{v}" }
  puts "  games left with 0 titles: #{empty_games.size}"
  unless empty_games.empty?
    puts '  examples:'
    empty_games.first(20).each { |p| puts "    #{p}" }
  end
end

main if __FILE__ == $PROGRAM_NAME
