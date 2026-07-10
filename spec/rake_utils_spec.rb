# frozen_string_literal: true

require "spec_helper"
require_relative "../lib/are_search/rake_utils"

RSpec.describe AreSearch::RakeUtils do
    describe ".searchable_index_target_for_reindex" do
        let(:application) { double("application", eager_load!: true) }
        let(:upper_target) do
            double(
                "upper_target",
                are_search_es_index_name: "test_articles_default",
            )
        end
        let(:lower_target) do
            double(
                "lower_target",
                are_search_es_index_name: "test_articles_default",
            )
        end
        let(:other_target) do
            double(
                "other_target",
                are_search_es_index_name: "test_documents_default",
            )
        end
        let(:upper_model) do
            class_double(
                "Article",
                are_search_index_targets: [upper_target],
            )
        end
        let(:lower_model) do
            class_double(
                "SpecialArticle",
                are_search_index_targets: [lower_target],
            )
        end
        let(:other_model) do
            class_double(
                "Document",
                are_search_index_targets: [other_target],
            )
        end

        before do
            allow(Rails)
                .to receive(:application)
                .and_return(application)

            allow(ActiveRecord::Base)
                .to receive(:descendants)
                .and_return([
                    lower_model,
                    other_model,
                    upper_model,
                ])

            [
                upper_model,
                lower_model,
                other_model,
            ].each do |model|
                allow(model)
                    .to receive(:include?)
                    .with(AreSearch::Searchable)
                    .and_return(true)

                allow(model)
                    .to receive(:<)
                    .and_return(nil)
            end

            allow(lower_model)
                .to receive(:<)
                .with(upper_model)
                .and_return(true)
        end

        it "Searchable の継承系統ごとに最も上位のモデルの index target を返す" do
            expect(lower_model)
                .not_to receive(:are_search_index_targets)

            result = described_class.searchable_index_target_for_reindex

            expect(result).to eq([
                other_target,
                upper_target,
            ])
        end
    end

    describe ".validate_searchable_index_name_ownership" do
        let(:application) { double("application", eager_load!: true) }
        let(:shared_target) do
            double(
                "shared_target",
                are_search_es_index_name: "test_articles_default",
            )
        end
        let(:other_target) do
            double(
                "other_target",
                are_search_es_index_name: "test_documents_default",
            )
        end
        let(:article_model) do
            class_double(
                "Article",
                name:                     "Article",
                are_search_index_targets: [shared_target],
            )
        end
        let(:sub_article_model) do
            class_double(
                "SubArticle",
                name:                     "SubArticle",
                are_search_index_targets: [shared_target],
            )
        end
        let(:sub_sub_article_model) do
            class_double(
                "SubSubArticle",
                name:                     "SubSubArticle",
                are_search_index_targets: [shared_target],
            )
        end
        let(:sibling_article_model) do
            class_double(
                "SiblingArticle",
                name:                     "SiblingArticle",
                are_search_index_targets: [shared_target],
            )
        end
        let(:document_model) do
            class_double(
                "Document",
                name:                     "Document",
                are_search_index_targets: [other_target],
            )
        end

        before do
            allow(Rails)
                .to receive(:application)
                .and_return(application)

            allow(ActiveRecord::Base)
                .to receive(:descendants)
                .and_return([
                    sub_sub_article_model,
                    sibling_article_model,
                    sub_article_model,
                    document_model,
                    article_model,
                ])

            [
                article_model,
                sub_article_model,
                sub_sub_article_model,
                sibling_article_model,
                document_model,
            ].each do |model|
                allow(model)
                    .to receive(:include?)
                    .with(AreSearch::Searchable)
                    .and_return(true)

                allow(model)
                    .to receive(:<)
                    .and_return(nil)
            end

            allow(sub_article_model)
                .to receive(:<)
                .with(article_model)
                .and_return(true)

            allow(sub_sub_article_model)
                .to receive(:<)
                .with(article_model)
                .and_return(true)

            allow(sub_sub_article_model)
                .to receive(:<)
                .with(sub_article_model)
                .and_return(true)

            allow(sibling_article_model)
                .to receive(:<)
                .with(article_model)
                .and_return(true)
        end

        it "同じ Searchable 祖先を持つ複数階層と兄弟モデルの同名 index を許可する" do
            errors = []

            result = described_class.validate_searchable_index_name_ownership(
                errors,
            )

            expect(result).to eq(true)
            expect(errors).to eq([])
        end

        it "別の継承系統が同じ index 名を持つ場合はエラーにする" do
            allow(document_model)
                .to receive(:are_search_index_targets)
                .and_return([shared_target])

            errors = []

            result = described_class.validate_searchable_index_name_ownership(
                errors,
            )

            expect(result).to eq(false)
            expect(errors).to eq([
                "継承関係のないモデルが同じ index を使用しています: " \
                    "test_articles_default: Article, Document",
            ])
        end
    end

    describe ".model_check" do
        def build_model_check_parent_class
            Class.new(ActiveRecord::Base) do
                self.abstract_class = true

                include AreSearch::Searchable

                def self.are_search_es_mappings
                    {
                        default: {
                            index_settings: {
                                max_result_window: 2_000,
                            },
                            properties: {
                                title: { type: "text" },
                            },
                        },
                    }
                end

                def are_search_es_data(_target_name)
                    {
                        title: "hello",
                    }
                end
            end
        end

        it "STI 子クラスが are_search_es_mappings を定義していればエラーにする" do
            parent_model = build_model_check_parent_class
            child_model = Class.new(parent_model) do
                self.abstract_class = true

                def self.are_search_es_mappings
                    {
                        default: {
                            index_settings: {
                                max_result_window: 2_000,
                            },
                            properties: {
                                title: { type: "text" },
                            },
                        },
                    }
                end
            end

            stub_const("ModelCheckParent", parent_model)
            stub_const("ModelCheckChild", child_model)

            errors = []

            expect do
                described_class.model_check(child_model, errors)
            end.to output(
                "are_search_es_data method_defined : true\n" \
                "are_search_es_mappings respond_to : true\n",
            ).to_stdout

            expect(errors).to eq([
                "ModelCheckChild: are_search_es_mappings は Searchable を include した上位クラスで定義してください。",
            ])
        end

        it "STI 子クラスが親の are_search_es_mappings を継承しているだけならエラーにしない" do
            parent_model = build_model_check_parent_class
            child_model = Class.new(parent_model) do
                self.abstract_class = true
            end

            stub_const("ModelCheckParent", parent_model)
            stub_const("ModelCheckChild", child_model)

            errors = []

            expect do
                described_class.model_check(child_model, errors)
            end.to output(
                "are_search_es_data method_defined : true\n" \
                "are_search_es_mappings respond_to : true\n",
            ).to_stdout

            expect(errors).to eq([])
        end
    end
end
