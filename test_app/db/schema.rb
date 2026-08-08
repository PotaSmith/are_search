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

ActiveRecord::Schema[8.1].define(version: 2026_08_08_090711) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "are_search_index_markers", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "index_alias_name", null: false
    t.text "message"
    t.string "operation", null: false
    t.string "owner_host"
    t.integer "owner_pid"
    t.string "owner_token", null: false
    t.datetime "started_at", null: false
    t.datetime "updated_at", null: false
    t.index ["index_alias_name"], name: "index_are_search_index_markers_on_index_alias_name", unique: true
  end

  create_table "are_search_sequences_for_sync_requests", force: :cascade do |t|
    t.datetime "created_at", null: false
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
    t.index ["ar_model_class_name", "ar_instance_key", "index_alias_name", "sync_stage_name"], name: "idx_on_ar_model_class_name_ar_instance_key_index_al_eea73fbecc", unique: true
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
