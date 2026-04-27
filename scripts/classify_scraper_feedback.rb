#!/usr/bin/env ruby
# frozen_string_literal: true

# Classify Retronian Scraper "unknown" feedback against local GameDB data.
#
# Usage:
#   ruby scripts/classify_scraper_feedback.rb
#   ruby scripts/classify_scraper_feedback.rb reports/unconverted.tsv reports/classified.tsv

require 'csv'
require 'json'
require 'fileutils'
require_relative 'lib/slug'

ROOT = File.expand_path('..', __dir__)
SRC = File.join(ROOT, 'data', 'games')
DEFAULT_INPUT = File.join(ROOT, 'reports', 'retronian-scraper-unconverted-unknown.tsv')
DEFAULT_OUTPUT = File.join(ROOT, 'reports', 'retronian-scraper-feedback-classified.tsv')

def load_platform_games(platform)
  dir = File.join(SRC, platform)
  return [] unless Dir.exist?(dir)

  Dir.glob(File.join(dir, '*.json')).sort.map { |path| JSON.parse(File.read(path)) }
end

def zip_source_to_rom_name(source)
  File.basename(source.to_s).sub(/\.zip\z/i, '')
end

def filename_key(name)
  File.basename(name.to_s).sub(/\.[^.]+\z/, '')
end

def add_match(index, key, match)
  return if key.nil? || key.empty?
  index[key] ||= []
  index[key] << match unless index[key].include?(match)
end

def build_indexes(games)
  exact = {}
  filename = {}
  base = {}

  games.each do |game|
    (game['roms'] || []).each do |rom|
      match = {
        'game_id' => game['id'],
        'rom_name' => rom['name'],
        'region' => rom['region'],
        'source' => rom['source']
      }.compact

      name = rom['name'].to_s
      add_match(exact, name, match)
      add_match(filename, filename_key(name), match)
      add_match(base, Slug.slugify(Slug.strip_no_intro_suffixes(name)), match)
    end
  end

  { exact: exact, filename: filename, base: base }
end

def classify(row, indexes_by_platform)
  platform = row.fetch('platform')
  source = row.fetch('source')
  rom_name = zip_source_to_rom_name(source)
  indexes = indexes_by_platform[platform] ||= build_indexes(load_platform_games(platform))

  exact_matches = indexes[:exact][rom_name] || []
  unless exact_matches.empty?
    return ['filename_exact_hash_mismatch_processable', exact_matches, 'Exact ROM filename exists in GameDB; process by filename and flag the hash mismatch for review.']
  end

  filename_matches = indexes[:filename][filename_key(source)] || []
  unless filename_matches.empty?
    return ['filename_exact_hash_mismatch_processable', filename_matches, 'Exact ROM filename exists in GameDB; process by filename and flag the hash mismatch for review.']
  end

  base_key = Slug.slugify(Slug.strip_no_intro_suffixes(rom_name))
  base_matches = indexes[:base][base_key] || []
  unless base_matches.empty?
    return ['filename_base_hash_mismatch_review', base_matches, 'Base ROM filename matches after stripping No-Intro suffixes; process as low confidence and review region/revision/hash.']
  end

  ['missing_or_wrong_platform', [], 'No ROM name match in this platform.']
end

input = ARGV[0] || DEFAULT_INPUT
output = ARGV[1] || DEFAULT_OUTPUT

abort "input not found: #{input}" unless File.exist?(input)

indexes_by_platform = {}
counts = Hash.new(0)

rows = CSV.read(input, headers: true, col_sep: "\t").map do |row|
  status, matches, note = classify(row, indexes_by_platform)
  counts[status] += 1

  {
    'platform' => row['platform'],
    'source' => row['source'],
    'classification' => status,
    'matched_game_id' => matches.map { |m| m['game_id'] }.uniq.join('|'),
    'matched_rom_name' => matches.map { |m| m['rom_name'] }.uniq.join('|'),
    'note' => note
  }
end

FileUtils.mkdir_p(File.dirname(output))
CSV.open(output, 'w', col_sep: "\t") do |csv|
  csv << rows.first.keys
  rows.each { |row| csv << row.values }
end

puts "wrote #{output}"
counts.sort.each { |status, count| puts "  #{status}: #{count}" }
