class CreateProducts < ActiveRecord::Migration[8.1]
  def change
    create_table :products do |t|
      t.string :name, null: false
      t.integer :stock, null: false

      t.check_constraint "stock >= 0", name: "products_stock_non_negative"
    end
  end
end
