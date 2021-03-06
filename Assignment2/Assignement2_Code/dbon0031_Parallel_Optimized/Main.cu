#include "jbutil.h"
#include <vector>
#include <limits>
#include <istream>
#include <cmath>
#include <string>
#include <cuda.h>

//struct to hold the motion vectors and MSE for each macroblock
struct block_data
{
	int motion_vector_x;
	int motion_vector_y;
	float MSE;
};

//struct to hold the 9 MSE - Searchblock pairs
struct MSE_per_Macroblock
{
	//0 -> top left block
	//1 -> top centre block
	//2 -> top right block
	//3 -> middle left block
	//4 -> middle centre block
	//5 -> middle right left block
	//6 -> bottom left block
	//7 -> bottom centre block
	//8 -> bottom right block
	float block[9];
};

//Parameters for the algorithm: macroblock width and height and search area parameters
int block_width = 8;
int block_height = 8;
int search_vertical = 8;
int search_horizontal = 8;
//the number of macroblocks along the x and y directions
int blocks_x;
int blocks_y;


//Function used to load frames
//Inputs: path for the images, the 2 frame images that will hold the frames
//Output: True if all load correctly, False if not
bool Load_Frames(std::string path, jbutil::image<int> &frame1,jbutil::image<int> &frame2)
	{
		//Load the 2 frames
			std::ifstream file;
			file.open((path+std::string("/frame1.ppm")).c_str());

			if(file)
			{
				frame1.load(file);
				#ifndef NDEBUG
					  std::cerr << "First Frame Loaded \n" << std::flush;
				#endif
			}
			else
			{
				#ifndef NDEBUG
					  std::cerr << "Error Loading First Frame \n" << std::flush;
				#endif
				return false;
			}

			file.close();


			file.open((path+std::string("/frame2.ppm")).c_str());
			if(file)
			{
				frame2.load(file);
				#ifndef NDEBUG
					  std::cerr << "Second Frame Loaded \n" << std::flush;
				#endif
			}
			else
			{
				#ifndef NDEBUG
					  std::cerr << "Error Loading Second Frame" << std::flush;
				#endif
				return false;
			}
			return true;
	}

//Function used to check the input parameters
//Inputs: image used to check parameters
//Output: True if all parameters are correct, False if not
bool Parameter_Check(jbutil::image<int> &frame_1)
{
	//checks to ensure that image width and height are exact multiplies of the block width and height
	if(!(frame_1.get_cols()%block_width == 0))
	{
		#ifndef NDEBUG
			  std::cerr << "Error: Block Width and Image Width are not exact multiples \n" << std::flush;
		#endif
		return false;
	}
	else if(!(frame_1.get_rows()%block_height == 0))
	{
		#ifndef NDEBUG
			  std::cerr << "Error: Block Height and Image Height are not exact multiples \n" << std::flush;
		#endif
		return false;
	}

	//check to ensure that the number of threads in a block are less than 1024
	if((block_width*block_height > 1024))
	{
		#ifndef NDEBUG
			  std::cerr << "Error: Block Size defined is too large! \n" << std::flush;
		#endif
		return false;
	}
	return true;
}

//Function used to create an image from a range in a given image
//Inputs: image from where to get range, image which is to be set (will be overwritten with the new range),
//        image parameters: channel start and stop, column start and stop,
//        row start and stop, top left pixel co-ordinates of where to set the range
//Output: None
void Modify_Image_Range(jbutil::image<int> &input, jbutil::image<int> &output, int channel_start, int channel_stop, int col_start, int col_stop, int row_start, int row_stop, int output_col, int output_row)
{
	for(int channel = channel_start; channel<channel_stop; channel++)	//for the defined channels
	{
		int row_count = 0;												//for the defined rows
		for (int row = row_start; row<row_stop; row++)
		{
			int col_count = 0;
			for(int col = col_start; col<col_stop; col++)				//for the defined columns
			{
				output(channel,output_row+row_count,output_col+col_count) = input(channel,row,col);	//set the range in the output image
				col_count++;
			}
			row_count++;
		}
	}
}

//Function to perform the linearization of the image
//Inputs: Image to be linearized, output array
//Output: None
void Linearize_Image(jbutil::image<int> &image, int* array)
{
	//linearize the image in such a way that memory is coalesced
	int index = 0;
	for (int row = 0; row<image.get_rows(); row++)
	{
		for(int col = 0; col<image.get_cols(); col++)
		{
			for(int channel = 0; channel<image.channels(); channel++)
			{
				array[index] = image(channel,row,col);
				index++;
			}
		}
	}
}

__global__ void Block_Match_Kernel(block_data* device_macroblocks, MSE_per_Macroblock* device_MSE_all_searches, int* device_frame_1, int* device_frame_2, int device_block_height,int device_block_width, int device_rows, int device_cols, int device_channels, int device_search_dist_x, int device_search_dist_y)
{
	#ifndef NDEBUG
		if((blockIdx.x == 0) && (blockIdx.y == 0) && (threadIdx.x == 0) && (threadIdx.y == 0))
		{
			printf("\nIN KERNEL");
		}
		__syncthreads();
	#endif


	//variable to store the MSE of the macroblock - search block pair
	__shared__ float MSE_pair;
	//variable to hold the index of the macroblock
	__shared__ int macroblock_index;

	//array to store results of the pixel_level MSE
	extern __shared__ float pixel_MSE[];
	//threads in the same block have the same search block start and stop co-ordinates
	__shared__ int search_area_x_start, search_area_x_stop, search_area_y_start, search_area_y_stop;




	pixel_MSE[threadIdx.x+threadIdx.y*device_block_width] = 0;

	//Initial setup of variables
	if (threadIdx.x == 0 && threadIdx.y == 0)
	{
		MSE_pair =0;
		macroblock_index = (blockIdx.x/9)+blockIdx.y*(device_cols/device_block_width);

		//%3 is needed since for 3 search blocks, the condition applies
		if (int(blockIdx.x% 3) == 0)
		{
			// divide by 9 is needed since every macroblock has 9 blocks along the x. This is not required for the y
			search_area_x_start = device_macroblocks[macroblock_index].motion_vector_x + int(blockIdx.x/9)*device_block_width - device_search_dist_x;
		}
		else if (int(blockIdx.x% 3) == 2)
		{
			search_area_x_start = device_macroblocks[macroblock_index].motion_vector_x + int(blockIdx.x/9)*device_block_width + device_search_dist_x;
		}
		else
		{
			search_area_x_start = device_macroblocks[macroblock_index].motion_vector_x + int(blockIdx.x/9)*device_block_width;
		}

		search_area_x_stop = search_area_x_start+device_block_width;

		//division by 3 and %3 is needed since, although this condition applies for 3 blocks, this time it is for the vertical
		//movement rather than the horizontal movement
		if (int((blockIdx.x/3)%3) == 0)
		{
			search_area_y_start = device_macroblocks[macroblock_index].motion_vector_y + blockIdx.y*device_block_height - device_search_dist_y;

		}
		else if (int((blockIdx.x/3)%3) == 2)
		{
			search_area_y_start = device_macroblocks[macroblock_index].motion_vector_y + blockIdx.y*device_block_height + device_search_dist_y;

		}
		else
		{
			search_area_y_start = device_macroblocks[macroblock_index].motion_vector_y + blockIdx.y*device_block_height;
		}

		search_area_y_stop = search_area_y_start+device_block_height;
	}


	__syncthreads();



	//if all of the search area parameters are within bounds
	if((search_area_x_start >= 0) && (search_area_x_stop <= device_cols) && (search_area_y_start >= 0) && (search_area_y_stop <= device_rows))
	{
		//get pixel co-ordinates for both frame 1 and frame 2
		int pixel_x_f1 = search_area_x_start+threadIdx.x;
		int pixel_y_f1 = search_area_y_start+threadIdx.y;

		int pixel_x_f2 = int(blockIdx.x/9)*device_block_width+threadIdx.x;
		int pixel_y_f2 = blockIdx.y*device_block_height+threadIdx.y;

		//get the pixel intensities and calculate the MSE
		for (int channel = 0; channel<device_channels; channel++)
		{
			int index_f1 = device_channels*pixel_x_f1+pixel_y_f1*device_channels*device_cols+channel;
			int index_f2 = device_channels*pixel_x_f2+pixel_y_f2*device_channels*device_cols+channel;

			//put the mse in the shared array
			pixel_MSE[threadIdx.x+threadIdx.y*device_block_width] = pixel_MSE[threadIdx.x+threadIdx.y*device_block_width] + (device_frame_1[index_f1]-device_frame_2[index_f2])*(device_frame_1[index_f1]-device_frame_2[index_f2]);
		}

	}



	if ((threadIdx.x == 0) && (threadIdx.y == 0))
	{
		//if within the search area, calculate the mse for the macroblock search block pair
		if((search_area_x_start >= 0) && (search_area_x_stop <= device_cols) && (search_area_y_start >= 0) && (search_area_y_stop <= device_rows))
		{
			for (int row = 0; row<device_block_height; row++)
			{
				for (int col = 0; col<device_block_width; col++)
				{
					MSE_pair = MSE_pair +pixel_MSE[col+row*device_block_width];
				}
			}
			MSE_pair = MSE_pair/float(device_block_height*device_block_width);
		}
		else
		{
			MSE_pair =50000000;
		}

		//write the MSE pair to a variable which will hold all the MSEs for all the macroblock and search block permutations
		device_MSE_all_searches[macroblock_index].block[int(blockIdx.x%9)] = MSE_pair;
	}


	#ifndef NDEBUG
		if((blockIdx.x == 0) && (blockIdx.y == 0) && (threadIdx.x == 0) && (threadIdx.y == 0))
		{
			printf("Finished Kernel Execution");
		}
	#endif

}

void Block_Match(jbutil::image<int> &frame_1,jbutil::image<int> &frame_2,jbutil::image<int> &reconstructed_frame2)
{
		//search dist parameters used in the three step search algorithm
		int search_dist_x = search_horizontal/2;
		int search_dist_y = search_vertical/2;

		//1st index = blocks along x, 2nd index => blocks along y
		//This 2D array will contain motion vectors in the x and y directions and MSE for each macroblock in the image
		blocks_x = frame_1.get_cols()/block_width;
		blocks_y = frame_1.get_rows()/block_height;

		//The following holds the MSE and motion vector for each macroblock in a linear manner
		block_data* macroblocks = (block_data*)malloc(blocks_x*blocks_y*sizeof(block_data));

		//The following holds the MSE for all the search blocks for every macroblock in a linear manner
		MSE_per_Macroblock* MSE_all_searches = (MSE_per_Macroblock*)malloc(blocks_x*blocks_y*sizeof(MSE_per_Macroblock));


		//Initialisation of the parmeters for each block
		for (int x = 0; x<blocks_x; x++)
		{
			for (int y = 0; y<blocks_y; y++)
			{
				int index = x+y*blocks_x;
				macroblocks[index].motion_vector_x = 0;
				macroblocks[index].motion_vector_y = 0;
				macroblocks[index].MSE = std::numeric_limits<float>::max();

				for (int search = 0; search<9; search++)
				{
					MSE_all_searches[index].block[search] = 0;
				}
			}
		}

		//Image details
		int rows = frame_1.get_rows();
		int cols = frame_1.get_cols();
		int channels = frame_1.channels();


		//Linearize the images, allocate space for them on the device and pass them to the device
		int array_size = frame_1.get_cols()*frame_1.get_rows()*frame_1.channels();

		int* array_frame_1 = (int*)std::malloc(sizeof(int)*array_size);
		Linearize_Image(frame_1, array_frame_1);
		int* device_frame_1;
		cudaMalloc((void**)&device_frame_1, sizeof(int)*array_size);
		cudaMemcpy(device_frame_1, array_frame_1, sizeof(int)*array_size, cudaMemcpyHostToDevice);

		int* array_frame_2 = (int*)std::malloc(sizeof(int)*array_size);
		Linearize_Image(frame_2, array_frame_2);
		int* device_frame_2;
		cudaMalloc((void**)&device_frame_2, sizeof(int)*array_size);
		cudaMemcpy(device_frame_2, array_frame_2, sizeof(int)*array_size, cudaMemcpyHostToDevice);

		//create the macroblock data for the device and allocate space
		block_data* device_macroblocks;
		cudaMalloc((void**)&device_macroblocks, blocks_x*blocks_y*sizeof(block_data));

		//create the the macroblock - searchblock pair mse data structure for the device and copy to device
		MSE_per_Macroblock* device_MSE_all_searches;
		cudaMalloc((void**)&device_MSE_all_searches, blocks_x*blocks_y*sizeof(MSE_per_Macroblock));
		cudaMemcpy(device_MSE_all_searches, MSE_all_searches, blocks_x*blocks_y*sizeof(MSE_per_Macroblock), cudaMemcpyHostToDevice);


		for (int search_count = 0; search_count<3;search_count++)	//for loop to denote the step in which the 3 step search has reached
		{
			//copy over the macroblock data. this must be done here since this data changes per iteration
			cudaMemcpy(device_macroblocks, macroblocks, blocks_x*blocks_y*sizeof(block_data), cudaMemcpyHostToDevice);

			//call the kernel
			dim3 Kernel_Blocks(9*blocks_x,blocks_y);
			dim3 Threads_Per_Block(block_width,block_height);

			Block_Match_Kernel<<<Kernel_Blocks,Threads_Per_Block, sizeof(float)*block_width*block_height>>>(device_macroblocks, device_MSE_all_searches, device_frame_1, device_frame_2, block_height, block_width, rows, cols, channels, search_dist_x, search_dist_y);

			//copy back the results
			cudaMemcpy(MSE_all_searches, device_MSE_all_searches, blocks_x*blocks_y*sizeof(MSE_per_Macroblock), cudaMemcpyDeviceToHost);


			//for every macroblock
			for (int x = 0; x<blocks_x; x++)
			{
				for (int y = 0; y<blocks_y; y++)
				{
					int index = x+y*blocks_x;
					int motion_vector_x_this_search = 0;
					int motion_vector_y_this_search = 0;
					//check all the possible search block pairs
					for (int search_block = 0 ; search_block<9; search_block++)
					{
						//if the mse for the macroblock search block pair is less that the currently set
						//mse, update the parameters for that macroblock
						//NB: MSE_all searches = 9*number of macroblocks, where:
							//index%8 = 0 -> top left block
							//index%8 = 1 -> top centre block
							//index%8 = 2 -> top right block
							//index%8 = 3 -> middle left block
							//index%8 = 4 -> middle centre block
							//index%8 = 5 -> middle right left block
							//index%8 = 6 -> bottom left block
							//index%8 = 7 -> bottom centre block
							//index%8 = 8 -> bottom right block

						if(MSE_all_searches[index].block[search_block]<macroblocks[index].MSE)
						{
							macroblocks[index].MSE = MSE_all_searches[index].block[search_block];
							motion_vector_x_this_search =  ((search_block%3)-1)*search_dist_x;
							motion_vector_y_this_search =  ((search_block/3)-1)*search_dist_y;
						}

					}
					macroblocks[index].motion_vector_x = macroblocks[index].motion_vector_x + motion_vector_x_this_search;
					macroblocks[index].motion_vector_y = macroblocks[index].motion_vector_y + motion_vector_y_this_search;

				}
			}

			//Update also the search dist parameters to get finer searches.
			//After 3 iterations, they should be set to 1 such that macroblocks differ by 1 pixel
			if(search_count == 1)
			{
				search_dist_x = 1;
				search_dist_y = 1;
			}
			else if(search_count != 2)
			{
				//using fast ceil - must be done since no guarantee division will result in exact multiples
				search_dist_x = int((search_dist_x+(search_dist_x/2)-1)/((search_dist_x/2)));
				search_dist_y = int((search_dist_y+(search_dist_y/2)-1)/((search_dist_y/2)));
			}

		}

		//Once the process is done, reconstruct the image
		for (int y = 0; y<blocks_y; y++)
		{
			for (int x = 0; x<blocks_x; x++)
			{

				int index = x+y*blocks_x;
				int x_start = x*block_width+macroblocks[index].motion_vector_x;
				int x_stop = x_start + block_width;

				int y_start = y*block_height+macroblocks[index].motion_vector_y;
				int y_stop = y_start + block_height;

				Modify_Image_Range(frame_1, reconstructed_frame2, 0, reconstructed_frame2.channels(), x_start, x_stop, y_start,y_stop, x*block_width, y*block_height);

			}
		}


		//Free all the memory allocations
		cudaFree(device_frame_1);
		cudaFree(device_frame_2);
		cudaFree(device_macroblocks);
		cudaFree(device_MSE_all_searches);

		std::free(array_frame_1);
		std::free(array_frame_2);
		std::free(macroblocks);
		std::free(MSE_all_searches);
}


//Main Function
int main(int argc, char* argv[])
{
	if(argc!=6)
	{
		#ifndef NDEBUG
			  std::cerr << "Not enough input arguments\n" << std::flush;
		#endif
		return 0;
	}

	block_width 		= atoi(argv[1]);
	block_height 		= atoi(argv[2]);
	search_vertical 	= atoi(argv[3]);
	search_horizontal 	= atoi(argv[4]);
	std::string path(argv[5]);

	if((block_width == 0) || (block_height == 0) || (search_vertical == 0) || (search_horizontal == 0))
	{
		#ifndef NDEBUG
			std::cerr<<"Integer parameters must be non-zero \n"<<std::flush;
		#endif
		return 0;
	}

	//Objects to hold the 2 frames
	jbutil::image<int> frame1;
	jbutil::image<int> frame2;


	//load frames
	if(!Load_Frames(path, frame1, frame2))
	{
		return 0;
	}

	//check the frames and parameters
	if(!Parameter_Check(frame1))
	{
		return 0;
	}

	//Object to hold the reconstructed frame 2
	jbutil::image<int> reconstructed_frame2(frame2.get_rows(),frame2.get_cols(),frame2.channels());

	#ifndef NDEBUG
		  std::cerr << "Entering Block Match Function\n" << std::flush;
	#endif

	//Run the Block Matching and Reconstruction
	double t = jbutil::gettime();
	Block_Match(frame1, frame2, reconstructed_frame2);
	t = jbutil::gettime() - t;

	std::cout << "Total Time taken: " << t << "s" << std::endl;
	#ifndef NDEBUG
		  std::cerr << "Exiting Block Match Function\n" << std::flush;
	#endif

	#ifndef NDEBUG
		  std::cerr << "Saving Reconstructed Frame\n" << std::flush;
	#endif
	std::ofstream output;
	output.open((path+std::string("/Reconstructed_Frame.ppm")).c_str());
	reconstructed_frame2.save(output);

	return 0;
}
