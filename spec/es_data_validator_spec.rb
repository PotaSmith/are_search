# frozen_string_literal: true

RSpec.describe AreSearch::EsDataValidator do
    describe ".validate" do
        let(:mappings) do
            {
                properties: {
                    title:      { type: "text" },
                    status:     { type: "keyword" },
                    count:      { type: "integer" },
                    price:      { type: "float" },
                    published:  { type: "boolean" },
                    published_at: { type: "date" },
                },
            }
        end

        it "returns an empty array when data matches mappings" do
            data = {
                title:        "title",
                status:       "published",
                count:        10,
                price:        12.5,
                published:    true,
                published_at: Time.now,
            }

            violations = described_class.validate(mappings, data)

            expect(violations).to eq([])
        end


        it "detects string properties key in mappings" do
            string_key_mappings = {
                "properties" => {
                    title: { type: "text" },
                },
            }
            data = {
                title: "title",
            }

            violations = described_class.validate(string_key_mappings, data)

            expect(violations).to eq([
                'mappings の key は Symbol で指定してください: "properties"',
            ])
        end

        it "detects string field keys in mappings" do
            string_key_mappings = {
                properties: {
                    "title" => { type: "text" },
                },
            }
            data = {
                title: "title",
            }

            violations = described_class.validate(string_key_mappings, data)

            expect(violations).to eq([
                'mappings.properties の key は Symbol で指定してください: "title"',
            ])
        end

        it "detects string type keys in mappings" do
            string_key_mappings = {
                properties: {
                    title: { "type" => "text" },
                },
            }
            data = {
                title: "title",
            }

            violations = described_class.validate(string_key_mappings, data)

            expect(violations).to eq([
                'mappings.properties.title の key は Symbol で指定してください: "type"',
            ])
        end

        it "detects string data keys" do
            data = {
                "title" => "title",
            }

            violations = described_class.validate(mappings, data)

            expect(violations).to eq([
                'data の key は Symbol で指定してください: "title"',
            ])
        end

        it "does not validate nested data hash keys" do
            object_mappings = {
                properties: {
                    payload: { type: "object" },
                },
            }
            data = {
                payload: {
                    "title" => "title",
                },
            }

            violations = described_class.validate(object_mappings, data)

            expect(violations).to eq([])
        end

        it "detects keys that exist only in data" do
            data = {
                title:        "title",
                status:       "published",
                count:        10,
                price:        12.5,
                published:    true,
                published_at: Time.now,
                extra:        "extra",
            }

            violations = described_class.validate(mappings, data)

            expect(violations).to include("mappings に定義の無いキーが data に含まれています: extra")
        end

        it "detects keys that exist only in mappings" do
            data = {
                title:        "title",
                status:       "published",
                count:        10,
                price:        12.5,
                published:    true,
            }

            violations = described_class.validate(mappings, data)

            expect(violations).to include("mappings に定義されているキーが data にありません: published_at")
        end

        it "accepts nil values" do
            data = {
                title:        nil,
                status:       nil,
                count:        nil,
                price:        nil,
                published:    nil,
                published_at: nil,
            }

            violations = described_class.validate(mappings, data)

            expect(violations).to eq([])
        end

        it "validates arrays by checking each element" do
            data = {
                title:        ["one", "two"],
                status:       ["published", "draft"],
                count:        [1, 2],
                price:        [1, 2.5],
                published:    [true, false],
                published_at: [Time.now, Date.today],
            }

            violations = described_class.validate(mappings, data)

            expect(violations).to eq([])
        end

        it "detects invalid elements in arrays" do
            data = {
                title:        ["valid", 123],
                status:       ["published", :draft],
                count:        [1, 2.5],
                price:        [1.0, "2.5"],
                published:    [true, "false"],
                published_at: [Time.now, :today],
            }

            violations = described_class.validate(mappings, data)

            expect(violations).to include("title は text 型ですが String ではありません: Integer")
            expect(violations).to include("status は keyword 型ですが String ではありません: Symbol")
            expect(violations).to include("count は integer 型ですが Integer ではありません: Float")
            expect(violations).to include("price は float 型ですが Integer/Float ではありません: String")
            expect(violations).to include("published は boolean 型ですが true/false ではありません: String")
            expect(violations).to include("published_at は date 型ですが Date/Time/DateTime/String/Integer ではありません: Symbol")
        end

        it "detects invalid text and keyword values" do
            data = {
                title:        123,
                status:       :published,
                count:        10,
                price:        12.5,
                published:    true,
                published_at: Time.now,
            }

            violations = described_class.validate(mappings, data)

            expect(violations).to include("title は text 型ですが String ではありません: Integer")
            expect(violations).to include("status は keyword 型ですが String ではありません: Symbol")
        end

        it "detects invalid integer values" do
            data = {
                title:        "title",
                status:       "published",
                count:        10.5,
                price:        12.5,
                published:    true,
                published_at: Time.now,
            }

            violations = described_class.validate(mappings, data)

            expect(violations).to include("count は integer 型ですが Integer ではありません: Float")
        end

        it "detects invalid float values" do
            data = {
                title:        "title",
                status:       "published",
                count:        10,
                price:        "12.5",
                published:    true,
                published_at: Time.now,
            }

            violations = described_class.validate(mappings, data)

            expect(violations).to include("price は float 型ですが Integer/Float ではありません: String")
        end

        it "detects invalid boolean values" do
            data = {
                title:        "title",
                status:       "published",
                count:        10,
                price:        12.5,
                published:    "true",
                published_at: Time.now,
            }

            violations = described_class.validate(mappings, data)

            expect(violations).to include("published は boolean 型ですが true/false ではありません: String")
        end

        it "detects invalid date values" do
            data = {
                title:        "title",
                status:       "published",
                count:        10,
                price:        12.5,
                published:    true,
                published_at: :today,
            }

            violations = described_class.validate(mappings, data)

            expect(violations).to include("published_at は date 型ですが Date/Time/DateTime/String/Integer ではありません: Symbol")
        end

        it "ignores unsupported mapping types" do
            unsupported_mappings = {
                properties: {
                    payload: { type: "object" },
                },
            }
            data = {
                payload: Object.new,
            }

            violations = described_class.validate(unsupported_mappings, data)

            expect(violations).to eq([])
        end

        it "handles mappings without properties" do
            data = {
                title: "title",
            }

            violations = described_class.validate({}, data)

            expect(violations).to eq(["mappings に定義の無いキーが data に含まれています: title"])
        end
    end
end
