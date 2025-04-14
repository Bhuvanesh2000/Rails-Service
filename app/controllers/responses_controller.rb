class ResponsesController < ApplicationController
  def create
    response = Response.create!(survey_id: params[:survey_id], user_id: params[:user_id])

    params[:answers].each do |answer|
      response.answers.create!(
        question_id: answer[:question_id],
        option_id: answer[:option_id]
      )
    end

    render json: response, status: :created
  end

  def show
    response = Response.includes(:answers).find(params[:id])
    render json: response.as_json(include: { answers: { include: :option } })
  end

  def update
    response = Response.find(params[:id])
    response.answers.destroy_all

    params[:answers].each do |answer|
      response.answers.create!(
        question_id: answer[:question_id],
        option_id: answer[:option_id]
      )
    end

    render json: { message: "Response updated." }
  end

  def user_responses
    responses = Response.where(user_id: params[:user_id], survey_id: params[:survey_id])
    render json: responses.as_json(include: :answers)
  end
end
