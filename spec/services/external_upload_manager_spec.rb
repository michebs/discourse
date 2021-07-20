# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ExternalUploadManager do
  fab!(:user) { Fabricate(:user) }
  let(:type) { "card_background" }
  let!(:logo_file) { file_from_fixtures("logo.png") }
  let!(:pdf_file) { file_from_fixtures("large.pdf", "pdf") }
  let(:object_size) { 1.megabyte }
  let(:etag) { "e696d20564859cbdf77b0f51cbae999a" }
  let(:client_sha1) { Upload.generate_digest(object_file) }
  let(:sha1) { Upload.generate_digest(object_file) }
  let(:object_file) { logo_file }
  let(:metadata_headers) { {} }
  let!(:external_upload_stub) { Fabricate(:image_external_upload_stub, created_by: user) }
  let(:upload_base_url) { "https://#{SiteSetting.s3_upload_bucket}.s3.#{SiteSetting.s3_region}.amazonaws.com" }

  subject do
    ExternalUploadManager.new(external_upload_stub)
  end

  before do
    SiteSetting.authorized_extensions += "|pdf"
    SiteSetting.max_attachment_size_kb = 210.megabytes / 1000

    setup_s3
    stub_head_object
    stub_download_object_filehelper
    stub_copy_object
    stub_delete_object
  end

  describe "#can_promote?" do
    it "returns false if the external stub status is not created" do
      external_upload_stub.update!(status: ExternalUploadStub.statuses[:uploaded])
      expect(subject.can_promote?).to eq(false)
    end
  end

  context "when stubbed upload is < DOWNLOAD_LIMIT (small enough to download + generate sha)" do
    let!(:external_upload_stub) { Fabricate(:image_external_upload_stub, created_by: user) }
    let(:object_size) { 1.megabyte }
    let(:object_file) { logo_file }

    context "when the download of the s3 file fails" do
      before do
        FileHelper.stubs(:download).returns(nil)
      end

      it "raises an error" do
        expect { subject.promote_to_upload! }.to raise_error(ExternalUploadManager::DownloadFailedError)
      end
    end

    context "when the sha has been set on the s3 object metadata by the clientside JS" do
      let(:metadata_headers) { { "x-amz-meta-sha1-checksum" => client_sha1 } }

      context "when the downloaded file sha1 does not match the client sha1" do
        let(:client_sha1) { "blahblah" }

        it "raises an error" do
          expect { subject.promote_to_upload! }.to raise_error(ExternalUploadManager::ChecksumMismatchError)
        end
      end

      context "when the upload does not get changed in UploadCreator (resized etc.)" do
        it "copies the stubbed upload on S3 to its new destination and deletes it" do
          upload = subject.promote_to_upload!
          expect(WebMock).to have_requested(
            :put,
            "https://#{SiteSetting.s3_upload_bucket}.s3.#{SiteSetting.s3_region}.amazonaws.com/original/1X/#{upload.sha1}.png"
          )
          expect(WebMock).to have_requested(
            :delete,
            "#{upload_base_url}/#{external_upload_stub.key}"
          )
        end
      end
    end
  end

  context "when stubbed upload is > DOWNLOAD_LIMIT (too big to download, generate a fake sha)" do
    let(:object_size) { 200.megabytes }
    let(:object_file) { pdf_file }
    let!(:external_upload_stub) { Fabricate(:attachment_external_upload_stub, created_by: user) }

    before do
      UploadCreator.any_instance.stubs(:generate_fake_sha1_hash).returns("testbc60eb18e8f974cbfae8bb0f069c3a311024")
    end

    it "does not try and download the file" do
      FileHelper.expects(:download).never
      subject.promote_to_upload!
    end

    # TODO: Test for attatchment + image size limits and also extension types
    it "generates a fake sha for the upload record" do
      upload = subject.promote_to_upload!
      expect(upload.sha1).not_to eq(sha1)
      expect(upload.original_sha1).to eq(nil)
      expect(upload.filesize).to eq(object_size)
    end

    it "copies the stubbed upload on S3 to its new destination and deletes it" do
      upload = subject.promote_to_upload!
      expect(WebMock).to have_requested(
        :put,
        "https://#{SiteSetting.s3_upload_bucket}.s3.#{SiteSetting.s3_region}.amazonaws.com/original/1X/#{upload.sha1}.pdf"
      )
      expect(WebMock).to have_requested(
        :delete,
        "#{upload_base_url}/#{external_upload_stub.key}"
      )
      expect(WebMock).to have_requested(
        :delete, "#{upload_base_url}/#{external_upload_stub.key}"
      )
    end
  end

  def stub_head_object
    stub_request(
      :head,
      "#{upload_base_url}/#{external_upload_stub.key}"
    ).to_return(
      status: 200,
      headers: {
        ETag: etag,
        "Content-Length" => object_size,
        "Content-Type" => "image/png",
      }.merge(metadata_headers)
    )
  end

  def stub_download_object_filehelper
    signed_url = Discourse.store.signed_url_for_path(external_upload_stub.key)
    stub_request(:get, signed_url).to_return(
      status: 200,
      body: object_file.read
    )
  end

  def stub_copy_object
    stub_request(
      :put,
      "#{upload_base_url}/original/1X/testbc60eb18e8f974cbfae8bb0f069c3a311024.pdf"
    ).to_return(
      status: 200,
      headers: { "ETag" => etag },
      body: <<~BODY)
<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n
<CopyObjectResult
	xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">
	<LastModified>2021-07-19T04:10:41.000Z</LastModified>
	<ETag>&quot;#{etag}&quot;</ETag>
</CopyObjectResult>
    BODY
    stub_request(
      :put,
      "#{upload_base_url}/original/1X/bc975735dfc6409c1c2aa5ebf2239949bcbdbd65.png"
    ).to_return(
      status: 200,
      headers: { "ETag" => etag },
      body: <<~BODY)
<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n
<CopyObjectResult
	xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">
	<LastModified>2021-07-19T04:10:41.000Z</LastModified>
	<ETag>&quot;#{etag}&quot;</ETag>
</CopyObjectResult>
    BODY
  end

  def stub_delete_object
    stub_request(
      :delete, "#{upload_base_url}/#{external_upload_stub.key}"
    ).to_return(
      status: 200
    )
  end
end
