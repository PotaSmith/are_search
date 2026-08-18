# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_18_072743) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "are_search_sequences_for_sync_requests", force: :cascade do |t|
    t.datetime "created_at", null: false
  end

  create_table "are_search_sync_locks", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "index_alias_name", null: false
    t.text "message"
    t.string "operation", null: false
    t.string "owner_host"
    t.integer "owner_pid"
    t.string "owner_token", null: false
    t.datetime "started_at", null: false
    t.string "sync_stage_name", null: false
    t.datetime "updated_at", null: false
    t.index ["index_alias_name", "sync_stage_name"], name: "idx_on_index_alias_name_sync_stage_name_a4b5260f78", unique: true
  end

  create_table "are_search_sync_request_boundary_targets", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "index_alias_name", null: false
    t.datetime "last_sync_ended_at"
    t.datetime "last_sync_started_at"
    t.text "message"
    t.bigint "sequence_limit", null: false
    t.string "sync_stage_name", null: false
    t.datetime "updated_at", null: false
    t.index ["index_alias_name", "sync_stage_name"], name: "idx_on_index_alias_name_sync_stage_name_fea505b9a7", unique: true
  end

  create_table "are_search_sync_requests", force: :cascade do |t|
    t.string "ar_instance_key", null: false
    t.string "ar_model_class_name", null: false
    t.integer "callback_try_count", default: 0, null: false
    t.datetime "created_at", null: false
    t.boolean "force_attempted", default: false, null: false
    t.integer "force_try_count", default: 0, null: false
    t.string "index_alias_name", null: false
    t.string "index_target_name", null: false
    t.datetime "last_callback_try_at"
    t.datetime "last_completed_at"
    t.text "last_error"
    t.datetime "last_error_at"
    t.datetime "last_force_try_at"
    t.datetime "last_sync_try_at"
    t.datetime "processing_at"
    t.string "processing_token"
    t.bigint "request_sequence", null: false
    t.datetime "request_sequence_at", null: false
    t.string "sync_stage_name", null: false
    t.integer "sync_try_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["index_alias_name", "sync_stage_name", "ar_instance_key"], name: "idx_on_index_alias_name_sync_stage_name_ar_instance_9415b0e07d", unique: true
    t.index ["index_alias_name", "sync_stage_name", "request_sequence"], name: "idx_on_index_alias_name_sync_stage_name_request_seq_224f3d51af"
    t.index ["sync_stage_name", "processing_at"], name: "idx_on_sync_stage_name_processing_at_48f1ecb85f"
    t.index ["sync_stage_name", "request_sequence_at"], name: "idx_on_sync_stage_name_request_sequence_at_f289d2b0e5"
  end

  create_table "document_firsts", force: :cascade do |t|
    t.text "body"
    t.datetime "created_at", null: false
    t.string "status"
    t.text "title"
    t.string "type"
    t.datetime "updated_at", null: false
    t.integer "user_id"
  end

  create_table "document_seconds", force: :cascade do |t|
    t.text "body"
    t.datetime "created_at", null: false
    t.string "status"
    t.text "title"
    t.string "type"
    t.datetime "updated_at", null: false
    t.integer "user_id"
  end
end
