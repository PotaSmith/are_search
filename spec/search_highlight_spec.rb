# frozen_string_literal: true

require "spec_helper"

RSpec.describe "search highlight" do
    let(:article_mappings) do
        {
            properties: {
                title: { type: "text" },
                body:  { type: "text" },
            },
        }
    end
    let(:document_mappings) do
        {
            properties: {
                title: { type: "text" },
                body:  { type: "text" },
            },
        }
    end
    let(:article_model) do
        class_double("Article", name: "Article")
    end
    let(:document_model) do
        class_double("Document", name: "Document")
    end
    let(:article_index_target) do
        double(
            "article_index_target",
            model_class:                  article_model,
            target_name:                  :default,
            are_search_es_index_name:     "test_articles_default",
            are_search_es_mappings:       article_mappings,
            are_search_es_index_settings: { max_result_window: 2_000 },
        )
    end
    let(:document_index_target) do
        double(
            "document_index_target",
            model_class:                  document_model,
            target_name:                  :default,
            are_search_es_index_name:     "test_documents_default",
            are_search_es_mappings:       document_mappings,
            are_search_es_index_settings: { max_result_window: 2_000 },
        )
    end

    before do
        allow(article_model)
            .to receive(:include?)
            .with(AreSearch::Searchable)
            .and_return(true)

        allow(document_model)
            .to receive(:include?)
            .with(AreSearch::Searchable)
            .and_return(true)

        allow(AreSearch::IndexManager)
            .to receive(:es_index_alias_exists?)
            .with("test_articles_default")
            .and_return(true)

        allow(AreSearch::IndexManager)
            .to receive(:es_index_alias_exists?)
            .with("test_documents_default")
            .and_return(true)
    end

    it "単一 target の MultiSearch は highlight fields が無ければ highlight body を作らない" do
        body = AreSearch::MultiSearch.search(
            [article_index_target],
            AreSearch::DumpBody,
            fields: [:title, :body],
            highlight: {
                fragment_size: 150,
            },
        )

        expect(body).not_to have_key(:highlight)
    end

    it "単一 target の MultiSearch は highlight の全オプションを body に渡す" do
        body = AreSearch::MultiSearch.search(
            [article_index_target],
            AreSearch::DumpBody,
            fields: [:title, :body],
            highlight: {
                fields:              { body: {} },
                fragment_size:       150,
                number_of_fragments: 3,
                type:                "unified",
            },
        )

        expect(body[:highlight]).to eq(
            pre_tags:            ["<em>"],
            post_tags:           ["</em>"],
            encoder:             "html",
            fields:              { body: {} },
            fragment_size:       150,
            number_of_fragments: 3,
            type:                "unified",
        )
    end

    it "MultiSearch は highlight fields が無ければ highlight body を作らない" do
        body = AreSearch::MultiSearch.search(
            [article_index_target, document_index_target],
            AreSearch::DumpBody,
            fields: [:title, :body],
            highlight: {
                fragment_size: 150,
            },
        )

        expect(body).not_to have_key(:highlight)
    end

    it "MultiSearch は利用側の highlight タグ設定を優先する" do
        body = AreSearch::MultiSearch.search(
            [article_index_target, document_index_target],
            AreSearch::DumpBody,
            fields: [:title, :body],
            highlight: {
                fields:    { body: {} },
                pre_tags:  ["<mark>"],
                post_tags: ["</mark>"],
                encoder:   "default",
            },
        )

        expect(body[:highlight]).to eq(
            pre_tags:  ["<mark>"],
            post_tags: ["</mark>"],
            encoder:   "default",
            fields:    { body: {} },
        )
    end

    it "MoreLikeThis は highlight fields が無ければ highlight body を作らない" do
        body = AreSearch::MoreLikeThis.search(
            [article_index_target],
            AreSearch::DumpBody,
            article_index_target,
            fields: [:title, :body],
            highlight: {
                fragment_size: 150,
            },
        )

        expect(body).not_to have_key(:highlight)
    end

    it "MoreLikeThis は highlight fields があれば highlight body を作る" do
        body = AreSearch::MoreLikeThis.search(
            [article_index_target],
            AreSearch::DumpBody,
            article_index_target,
            fields: [:title, :body],
            highlight: {
                fields:        [:body],
                fragment_size: 150,
            },
        )

        expect(body[:highlight]).to eq(
            pre_tags:     ["<em>"],
            post_tags:    ["</em>"],
            encoder:      "html",
            fields:       { body: {} },
            fragment_size: 150,
        )
    end
end
