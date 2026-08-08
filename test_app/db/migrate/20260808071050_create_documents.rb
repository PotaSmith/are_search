class CreateDocuments < ActiveRecord::Migration[8.1]
  def change
    create_table :document_firsts do |t|
      t.string :type

      t.text :title
      t.text :body
      t.string :status
      t.integer :user_id

      t.timestamps
    end
    create_table :document_seconds do |t|
      t.string :type

      t.text :title
      t.text :body
      t.string :status
      t.integer :user_id

      t.timestamps
    end
  end
end
