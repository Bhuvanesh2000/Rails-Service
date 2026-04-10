class CreateRequests < ActiveRecord::Migration[8.0]
  def change
    create_table :requests do |t|
      t.string :idempotency_key, null: false
      t.string :status, null: false, default: 'pending'
      t.string  :request_type, null: false
      t.integer :external_id, null: false
      t.integer :attempts, null: false, default: 0
      t.integer :max_attempts, null: false, default: 5
      t.jsonb :payload, null: false, default: {}
      t.string :error_message
      t.jsonb :response
      t.datetime :locked_at
      t.integer :lock_version, null: false, default: 0

      t.timestamps
    end
    add_index :requests, :idempotency_key, unique: true
    add_index :requests, :status
  end
end
