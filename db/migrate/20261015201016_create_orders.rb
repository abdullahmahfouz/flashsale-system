class CreateOrders < ActiveRecord::Migration[8.1]
  def change
    create_table :orders do |t|
      t.references :product, null: false, foreign_key: true
      t.string :user_id
      t.integer :quantity
      t.string :status
      t.string :idempotency_key

      t.timestamps
    end

    add_index :orders, :idempotency_key, unique: true
  end
end
