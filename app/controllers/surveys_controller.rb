class SurveysController < ApplicationController
  accepts_nested_attributes_for :questions

  def create
    survey = Survey.create!(survey_params)
    render json: survey, status: :created
  end

  def index
    surveys = Survey.all.includes(:questions)
    render json: surveys.as_json(include: { questions: { include: :options } })
  end

  private

  def survey_params
    params.require(:survey).permit(:title, :description,
      questions_attributes: [:text, :question_type, options_attributes: [:text]]
    )
  end
end
