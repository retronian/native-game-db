# frozen_string_literal: true

require 'json'
require_relative 'slug'

# Shared helpers for building a slug -> { path, game } lookup index for
# a given platform, plus a matching lookup helper.
#
# The index is built in two passes so that file id always wins over a
# title alias. Without this, an IGDB-translated entry like
# "carpenter-genzo-robot-empire.json" can register
# "daiku-no-gen-san-robot-teikoku-no-yabou" as one of its Latin title
# aliases and then swallow the romu merge for the real
# daiku-no-gen-san-robot-teikoku-no-yabou.json file.
module DbIndex
  module_function

  def build(src_root, platform_id)
    dir = File.join(src_root, platform_id)
    return {} unless Dir.exist?(dir)

    records = Dir.glob(File.join(dir, '*.json')).sort.map do |path|
      { path: path, game: JSON.parse(File.read(path)) }
    end

    index = {}

    # Pass 1: strong keys (file id and its numeric aliases) always win.
    records.each do |record|
      id = record[:game]['id']
      next if id.nil? || id.empty?
      [id, Slug.normalize_numerals(id), Slug.canonical(id)].compact.uniq.each do |k|
        index[k] = record
      end
    end

    # Pass 2: weak keys (aliases derived from Latin title text) only
    # fill holes that Pass 1 did not cover.
    records.each do |record|
      record[:game]['titles'].each do |t|
        next unless t['script'] == 'Latn'
        Slug.aliases_for(t['text']).each { |k| index[k] ||= record }
      end
    end

    index
  end

  def lookup(index, text)
    Slug.aliases_for(text).each { |k| return index[k] if index.key?(k) }
    nil
  end
end
