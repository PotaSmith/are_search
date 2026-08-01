# frozen_string_literal: true

require "spec_helper"

RSpec.describe AreSearch::SearchOptionContext do
    describe ".build" do
        it "modelsをモデルClassのArrayに限定する" do
            expect do
                described_class.build([], nil, {})
            end.to raise_error(
                ArgumentError,
                "context.models は Array で指定してください: nil",
            )

            invalid_model = Object.new

            expect do
                described_class.build([], [invalid_model], {})
            end.to raise_error(
                ArgumentError,
                /context\.models はモデルClassのArrayで指定してください/,
            )
        end

        it "modelsの重複を除く" do
            model = Class.new

            context = described_class.build([], [model, model], {})

            expect(context.models).to eq([model])
        end
    end
end
