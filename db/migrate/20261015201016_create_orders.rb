class CreateOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :orders do |t|
      t.references :product, null: false, foreign_key: true
      t.bigint :user_id, null: false
      t.integer :quantity, null: false
      t.string :status, null: false
      t.string :idempotency_key, null: false
      t.datetime :created_at, null: false
    end

    add_index :orders, :idempotency_key, unique: true
  end
end
