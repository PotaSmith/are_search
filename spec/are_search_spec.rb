# frozen_string_literal: true

RSpec.describe AreSearch do
    it "has a version number" do
        expect(AreSearch::VERSION).not_to be nil
    end

    describe ".multi_search" do
        it "query を query_string として Searcherへ渡す" do
            index_targets = [double("index_target")]

            expect(AreSearch::Searcher)
                .to receive(:search)
                .with(
                    index_targets,
                    query_string: "Rails",
                    fields:       [:title],
                )
                .and_return(:search_result)

            result = described_class.multi_search(
                index_targets,
                "Rails",
                fields: [:title],
            )

            expect(result).to eq(:search_result)
        end
    end

    describe ".more_like_this" do
        it "mltをMore Like This用オプションとして Searcherへ渡す" do
            index_targets = [double("search_target")]
            instance = double("article")
            index_target = double("article_index_target")

            expect(AreSearch::Searcher)
                .to receive(:search)
                .with(
                    index_targets,
                    mlt: {
                        instance:     instance,
                        index_target: index_target,
                        fields:       [:title],
                    },
                    page: 2,
                )
                .and_return(:search_result)

            result = described_class.more_like_this(
                index_targets,
                mlt: {
                    instance:     instance,
                    index_target: index_target,
                    fields:       [:title],
                },
                page: 2,
            )

            expect(result).to eq(:search_result)
        end
    end
end
