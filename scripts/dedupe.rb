#!/usr/bin/env ruby
# frozen_string_literal: true

# Merge duplicate game entries on the same platform.
#
# Two entries are considered the same game when any of the following
# holds:
#   - same external_ids.wikidata
#   - same external_ids.igdb
#   - same external_ids.mobygames
#
# When duplicates are found we keep the file whose id matches the
# canonical English title slug (usually the Wikidata-seeded one) and
# fold the other entry into it:
#   - union titles[] (deduped by text/lang)
#   - union descriptions[] (deduped by text/lang)
#   - union developers/publishers/genres
#   - union external_ids (preferring the kept entry's values on
#     conflict — the wikidata-seeded ids are generally correct)
#   - keep the earlier first_release_date if both entries have one
#
# Usage:
#   ruby scripts/dedupe.rb                # all platforms
#   ruby scripts/dedupe.rb --dry-run
#   ruby scripts/dedupe.rb --platform gb

require 'json'
require 'fileutils'
require 'optparse'
require_relative 'lib/slug'

$stdout.sync = true

ROOT = File.expand_path('..', __dir__)
SRC  = File.join(ROOT, 'data', 'games')

def normalize(text)
  text.to_s.unicode_normalize(:nfkc).strip.downcase.gsub(/\s+/, ' ')
end

def load_platform(platform_id)
  dir = File.join(SRC, platform_id)
  return [] unless Dir.exist?(dir)
  Dir.glob(File.join(dir, '*.json')).sort.map do |path|
    { path: path, game: JSON.parse(File.read(path)) }
  end
end

# Pick a "signature" key to group duplicates. We prefer Wikidata QID,
# then IGDB id, then MobyGames id.
def signatures(game)
  ids = game['external_ids'] || {}
  sigs = []
  sigs << "wikidata:#{ids['wikidata']}" if ids['wikidata']
  sigs << "igdb:#{ids['igdb']}"         if ids['igdb']
  sigs << "mobygames:#{ids['mobygames']}" if ids['mobygames']
  sigs
end

def english_title(game)
  t = game['titles'].find { |x| x['lang'] == 'en' && x['script'] == 'Latn' }
  t&.dig('text')
end

# Which of two records should we keep?
# Prefer the one whose id matches the English-title slug (that's the
# Wikidata-seeded canonical file), then the one with more titles.
def choose_survivor(a, b)
  a_en_slug = Slug.slugify(english_title(a[:game]))
  b_en_slug = Slug.slugify(english_title(b[:game]))

  a_match = a[:game]['id'] == a_en_slug
  b_match = b[:game]['id'] == b_en_slug

  return [a, b] if a_match && !b_match
  return [b, a] if b_match && !a_match

  # Tie-break: more titles wins, then earlier file mtime.
  if a[:game]['titles'].size != b[:game]['titles'].size
    return a[:game]['titles'].size > b[:game]['titles'].size ? [a, b] : [b, a]
  end

  [a, b]
end

def union_titles(keep, drop)
  seen = keep.map { |t| [t['lang'], normalize(t['text'])] }.to_set
  drop.each do |t|
    key = [t['lang'], normalize(t['text'])]
    next if seen.include?(key)
    seen << key
    keep << t
  end
  keep
end

require 'set'

def union_descriptions(keep, drop)
  keep ||= []
  drop ||= []
  seen = keep.map { |d| [d['lang'], normalize(d['text'])] }.to_set
  drop.each do |d|
    key = [d['lang'], normalize(d['text'])]
    next if seen.include?(key)
    seen << key
    keep << d
  end
  keep
end

def union_list(a, b)
  ((a || []) + (b || [])).uniq
end

def merge_external_ids(keep, drop)
  merged = (keep || {}).dup
  (drop || {}).each do |k, v|
    merged[k] ||= v
  end
  merged
end

def earlier_date(a, b)
  return b if a.nil?
  return a if b.nil?
  [a, b].min
end

def merge_into(target, source)
  target['titles'] = union_titles(target['titles'], source['titles'])
  target['descriptions'] = union_descriptions(target['descriptions'], source['descriptions'])
  target['developers']   = union_list(target['developers'], source['developers'])
  target['publishers']   = union_list(target['publishers'], source['publishers'])
  target['genres']       = union_list(target['genres'], source['genres'])
  target['external_ids'] = merge_external_ids(target['external_ids'], source['external_ids'])
  %w[developers publishers genres].each { |f| target.delete(f) if target[f].empty? }
  target.delete('descriptions') if (target['descriptions'] || []).empty?
  target.delete('external_ids') if (target['external_ids'] || {}).empty?
  target['first_release_date'] = earlier_date(target['first_release_date'], source['first_release_date'])
  target.delete('first_release_date') if target['first_release_date'].nil?
  target
end

def process_platform(platform_id, dry_run:)
  records = load_platform(platform_id)
  return { files: 0, duplicates: 0, merged: 0, removed: 0 } if records.empty?

  # Group records by any shared external id.
  groups = {}
  records.each do |r|
    sigs = signatures(r[:game])
    if sigs.empty?
      groups[r[:path]] = [r]
    else
      # Merge groups that share any sig.
      matching_keys = sigs.select { |s| groups.key?(s) }
      if matching_keys.empty?
        sigs.each { |s| groups[s] = [r] }
      else
        primary = matching_keys.first
        groups[primary] << r
        matching_keys.drop(1).each do |k|
          groups[primary].concat(groups.delete(k))
        end
        sigs.each { |s| groups[s] ||= groups[primary] }
      end
    end
  end

  # Collapse groups by identity (same array reference) to avoid
  # processing the same group through multiple signature keys.
  seen = {}
  unique_groups = []
  groups.each_value do |g|
    oid = g.object_id
    next if seen[oid]
    seen[oid] = true
    unique_groups << g
  end

  stats = { files: records.size, duplicates: 0, merged: 0, removed: 0 }

  unique_groups.each do |group|
    group = group.uniq { |r| r[:path] }
    next if group.size < 2
    stats[:duplicates] += 1

    survivor = group.first
    group.drop(1).each do |other|
      survivor, loser = choose_survivor(survivor, other)
      merge_into(survivor[:game], loser[:game])
      unless dry_run
        File.write(survivor[:path], JSON.pretty_generate(survivor[:game]) + "\n")
        File.delete(loser[:path])
      end
      stats[:merged] += 1
      stats[:removed] += 1
    end
  end

  stats
end

def main
  options = { dry_run: false, platform: nil }
  OptionParser.new do |opts|
    opts.banner = 'Usage: ruby scripts/dedupe.rb [options]'
    opts.on('--dry-run') { options[:dry_run] = true }
    opts.on('--platform ID') { |p| options[:platform] = p }
  end.parse!

  puts '=== dedupe ==='
  puts

  platforms = options[:platform] ? [options[:platform]] : Dir.glob(File.join(SRC, '*')).map { |d| File.basename(d) }.sort

  overall = Hash.new(0)
  platforms.each do |platform_id|
    stats = process_platform(platform_id, dry_run: options[:dry_run])
    puts "  #{platform_id.ljust(5)} files=#{stats[:files]}, dup-groups=#{stats[:duplicates]}, merged=#{stats[:merged]}, removed=#{stats[:removed]}"
    stats.each { |k, v| overall[k] += v }
  end

  puts
  puts '=== Overall ==='
  overall.each { |k, v| puts "  #{k}: #{v}" }
end

main if __FILE__ == $PROGRAM_NAME
