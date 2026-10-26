class ItemsController < ApplicationController
  def index
    render json: Item.order(:id).limit(100)
  end

  def show
    render json: Item.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render json: { error: "not found" }, status: :not_found
  end

  def create
    item = Item.new(params.permit(:name, :quantity))
    if item.save
      render json: item, status: :created
    else
      render json: { errors: item.errors.full_messages }, status: :unprocessable_content
    end
  end
end
